#include "InferPeerLlamaBridge.h"

#include <llama/llama.h>
#include <llama/mtmd-helper.h>
#include <llama/mtmd.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

struct IPLlamaSession {
    llama_model * model = nullptr;
    mtmd_context * multimodal = nullptr;
    uint32_t context_tokens = 0;
    std::atomic<bool> cancelled = false;
};

namespace {

void set_error(char * buffer, size_t size, const std::string & message) {
    if (buffer == nullptr || size == 0) {
        return;
    }
    const size_t count = std::min(size - 1, message.size());
    std::memcpy(buffer, message.data(), count);
    buffer[count] = '\0';
}

std::string formatted_prompt(
    const llama_model * model,
    const char * const * roles,
    const char * const * contents,
    size_t count,
    size_t media_count,
    std::string & error
) {
    std::vector<std::string> role_storage;
    std::vector<std::string> content_storage;
    role_storage.reserve(count);
    content_storage.reserve(count);
    for (size_t index = 0; index < count; ++index) {
        role_storage.emplace_back(roles[index] == nullptr ? "user" : roles[index]);
        content_storage.emplace_back(contents[index] == nullptr ? "" : contents[index]);
    }
    if (media_count > 0) {
        const std::string marker = mtmd_default_marker();
        std::string prefix;
        for (size_t index = 0; index < media_count; ++index) {
            prefix += marker + "\n";
        }
        auto user = std::find(role_storage.rbegin(), role_storage.rend(), "user");
        const size_t target = user == role_storage.rend()
            ? content_storage.size() - 1
            : role_storage.size() - 1 - static_cast<size_t>(user - role_storage.rbegin());
        content_storage[target] = prefix + content_storage[target];
    }

    std::vector<llama_chat_message> messages;
    messages.reserve(count);
    for (size_t index = 0; index < count; ++index) {
        messages.push_back({role_storage[index].c_str(), content_storage[index].c_str()});
    }
    const char * model_template = llama_model_chat_template(model, nullptr);
    int32_t required = llama_chat_apply_template(
        model_template,
        messages.data(),
        messages.size(),
        true,
        nullptr,
        0
    );
    if (required < 0) {
        error = "llama.cpp could not apply the model chat template";
        return {};
    }
    std::vector<char> buffer(static_cast<size_t>(required) + 1);
    required = llama_chat_apply_template(
        model_template,
        messages.data(),
        messages.size(),
        true,
        buffer.data(),
        static_cast<int32_t>(buffer.size())
    );
    if (required < 0) {
        error = "llama.cpp could not write the formatted prompt";
        return {};
    }
    return std::string(buffer.data(), static_cast<size_t>(required));
}

std::vector<llama_token> tokenize(
    const llama_vocab * vocab,
    const std::string & prompt,
    std::string & error
) {
    const int32_t required = -llama_tokenize(
        vocab,
        prompt.data(),
        static_cast<int32_t>(prompt.size()),
        nullptr,
        0,
        true,
        true
    );
    if (required <= 0) {
        error = "llama.cpp could not size the prompt token buffer";
        return {};
    }
    std::vector<llama_token> tokens(static_cast<size_t>(required));
    const int32_t count = llama_tokenize(
        vocab,
        prompt.data(),
        static_cast<int32_t>(prompt.size()),
        tokens.data(),
        static_cast<int32_t>(tokens.size()),
        true,
        true
    );
    if (count < 0) {
        error = "llama.cpp could not tokenize the prompt";
        return {};
    }
    tokens.resize(static_cast<size_t>(count));
    return tokens;
}

bool evaluate_text(
    llama_context * context,
    const std::vector<llama_token> & tokens,
    uint32_t batch_size,
    std::string & error
) {
    size_t offset = 0;
    while (offset < tokens.size()) {
        const size_t count = std::min<size_t>(batch_size, tokens.size() - offset);
        llama_batch batch = llama_batch_get_one(
            const_cast<llama_token *>(tokens.data() + offset),
            static_cast<int32_t>(count)
        );
        if (llama_decode(context, batch) != 0) {
            error = "llama.cpp failed while evaluating prompt tokens";
            return false;
        }
        offset += count;
    }
    return true;
}

struct BitmapOwner {
    mtmd_bitmap * bitmap = nullptr;
    mtmd_helper_video * video = nullptr;

    ~BitmapOwner() {
        if (bitmap != nullptr) {
            mtmd_bitmap_free(bitmap);
        }
        if (video != nullptr) {
            mtmd_helper_video_free(video);
        }
    }
};

bool evaluate_media(
    IPLlamaSession * session,
    llama_context * context,
    const std::string & prompt,
    const char * const * media_paths,
    size_t media_count,
    uint32_t batch_size,
    uint32_t & token_count,
    std::string & error
) {
    std::vector<std::unique_ptr<BitmapOwner>> owners;
    std::vector<const mtmd_bitmap *> bitmaps;
    const mtmd_helper_init_opt options = mtmd_helper_init_opt_default();
    for (size_t index = 0; index < media_count; ++index) {
        auto wrapper = mtmd_helper_bitmap_init_from_file(
            session->multimodal,
            media_paths[index],
            false,
            options
        );
        if (wrapper.bitmap == nullptr) {
            error = "libmtmd could not decode a media input";
            return false;
        }
        auto owner = std::make_unique<BitmapOwner>();
        owner->bitmap = wrapper.bitmap;
        owner->video = wrapper.video_ctx;
        bitmaps.push_back(wrapper.bitmap);
        owners.push_back(std::move(owner));
    }

    std::unique_ptr<mtmd_input_chunks, decltype(&mtmd_input_chunks_free)> chunks(
        mtmd_input_chunks_init(),
        mtmd_input_chunks_free
    );
    const mtmd_input_text input = {
        prompt.data(),
        prompt.size(),
        true,
        true,
    };
    const int32_t tokenize_result = mtmd_tokenize(
        session->multimodal,
        chunks.get(),
        &input,
        bitmaps.data(),
        bitmaps.size()
    );
    if (tokenize_result != 0) {
        error = "libmtmd could not tokenize the multimodal prompt";
        return false;
    }
    llama_pos new_position = 0;
    const int32_t evaluate_result = mtmd_helper_eval_chunks(
        session->multimodal,
        context,
        chunks.get(),
        0,
        0,
        static_cast<int32_t>(batch_size),
        true,
        &new_position
    );
    if (evaluate_result != 0) {
        error = "libmtmd could not evaluate the multimodal prompt";
        return false;
    }
    token_count = static_cast<uint32_t>(mtmd_helper_get_n_tokens(chunks.get()));
    return true;
}

llama_sampler * make_sampler(float temperature, float top_p, uint32_t seed) {
    llama_sampler * sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (temperature <= 0.0F) {
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
        return sampler;
    }
    if (top_p > 0.0F && top_p < 1.0F) {
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(top_p, 1));
    }
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed));
    return sampler;
}

std::string token_piece(const llama_vocab * vocab, llama_token token) {
    std::vector<char> buffer(256);
    int32_t count = llama_token_to_piece(
        vocab,
        token,
        buffer.data(),
        static_cast<int32_t>(buffer.size()),
        0,
        true
    );
    if (count < 0) {
        buffer.resize(static_cast<size_t>(-count));
        count = llama_token_to_piece(
            vocab,
            token,
            buffer.data(),
            static_cast<int32_t>(buffer.size()),
            0,
            true
        );
    }
    return count > 0 ? std::string(buffer.data(), static_cast<size_t>(count)) : std::string();
}

int32_t generate_tokens(
    IPLlamaSession * session,
    llama_context * context,
    uint32_t maximum,
    float temperature,
    float top_p,
    uint32_t seed,
    IPLLamaTokenCallback callback,
    void * callback_context,
    uint32_t & generated,
    bool & reached_end,
    std::string & error
) {
    const llama_vocab * vocab = llama_model_get_vocab(session->model);
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
        make_sampler(temperature, top_p, seed),
        llama_sampler_free
    );
    for (uint32_t index = 0; index < maximum; ++index) {
        if (session->cancelled.load()) {
            return 2;
        }
        const llama_token token = llama_sampler_sample(sampler.get(), context, -1);
        if (llama_vocab_is_eog(vocab, token)) {
            reached_end = true;
            return 0;
        }
        const std::string piece = token_piece(vocab, token);
        if (!piece.empty() && callback != nullptr) {
            callback(piece.data(), static_cast<int32_t>(piece.size()), callback_context);
        }
        ++generated;
        llama_token next = token;
        llama_batch batch = llama_batch_get_one(&next, 1);
        if (index + 1 < maximum && llama_decode(context, batch) != 0) {
            error = "llama.cpp failed while evaluating a generated token";
            return 1;
        }
    }
    return 0;
}

}  // namespace

IPLlamaSession * ipl_llama_session_create(
    const char * model_path,
    const char * projector_path,
    uint32_t context_tokens,
    int32_t gpu_layers,
    char * error_buffer,
    size_t error_buffer_size
) {
    if (model_path == nullptr || context_tokens == 0) {
        set_error(error_buffer, error_buffer_size, "invalid llama.cpp model configuration");
        return nullptr;
    }
    ggml_backend_load_all();
    auto session = std::make_unique<IPLlamaSession>();
    llama_model_params parameters = llama_model_default_params();
    parameters.n_gpu_layers = gpu_layers;
    session->model = llama_model_load_from_file(model_path, parameters);
    if (session->model == nullptr) {
        set_error(error_buffer, error_buffer_size, "llama.cpp could not load the GGUF model");
        return nullptr;
    }
    session->context_tokens = context_tokens;
    if (projector_path != nullptr) {
        mtmd_context_params mtmd_parameters = mtmd_context_params_default();
        mtmd_parameters.use_gpu = true;
        session->multimodal = mtmd_init_from_file(
            projector_path,
            session->model,
            mtmd_parameters
        );
        if (session->multimodal == nullptr) {
            set_error(error_buffer, error_buffer_size, "libmtmd could not load the projector");
            llama_model_free(session->model);
            return nullptr;
        }
    }
    return session.release();
}

bool ipl_llama_session_supports_vision(const IPLlamaSession * session) {
    return session != nullptr && session->multimodal != nullptr
        && mtmd_support_vision(session->multimodal);
}

int32_t ipl_llama_generate(
    IPLlamaSession * session,
    const char * const * roles,
    const char * const * contents,
    size_t message_count,
    const char * const * media_paths,
    size_t media_count,
    uint32_t maximum_output_tokens,
    float temperature,
    float top_p,
    uint32_t seed,
    IPLLamaTokenCallback callback,
    void * callback_context,
    uint32_t * prompt_tokens,
    uint32_t * output_tokens,
    bool * reached_end_token,
    char * error_buffer,
    size_t error_buffer_size
) {
    if (session == nullptr || message_count == 0 || maximum_output_tokens == 0) {
        set_error(error_buffer, error_buffer_size, "invalid llama.cpp generation request");
        return 1;
    }
    if (media_count > 0 && !ipl_llama_session_supports_vision(session)) {
        set_error(error_buffer, error_buffer_size, "this llama.cpp session has no vision projector");
        return 1;
    }
    session->cancelled.store(false);
    std::string error;
    const std::string prompt = formatted_prompt(
        session->model,
        roles,
        contents,
        message_count,
        media_count,
        error
    );
    if (!error.empty()) {
        set_error(error_buffer, error_buffer_size, error);
        return 1;
    }

    llama_context_params parameters = llama_context_default_params();
    parameters.n_ctx = session->context_tokens;
    parameters.n_batch = std::min<uint32_t>(session->context_tokens, 1024);
    parameters.n_ubatch = parameters.n_batch;
    parameters.no_perf = false;
    std::unique_ptr<llama_context, decltype(&llama_free)> context(
        llama_init_from_model(session->model, parameters),
        llama_free
    );
    if (!context) {
        set_error(error_buffer, error_buffer_size, "llama.cpp could not create an inference context");
        return 1;
    }

    uint32_t prompt_count = 0;
    bool evaluated = false;
    if (media_count > 0) {
        evaluated = evaluate_media(
            session,
            context.get(),
            prompt,
            media_paths,
            media_count,
            parameters.n_batch,
            prompt_count,
            error
        );
    } else {
        const std::vector<llama_token> tokens = tokenize(
            llama_model_get_vocab(session->model),
            prompt,
            error
        );
        prompt_count = static_cast<uint32_t>(tokens.size());
        evaluated = !tokens.empty()
            && evaluate_text(context.get(), tokens, parameters.n_batch, error);
    }
    if (!evaluated) {
        set_error(error_buffer, error_buffer_size, error);
        return 1;
    }

    uint32_t generated = 0;
    bool reached_end = false;
    const int32_t result = generate_tokens(
        session,
        context.get(),
        maximum_output_tokens,
        temperature,
        top_p,
        seed,
        callback,
        callback_context,
        generated,
        reached_end,
        error
    );
    if (prompt_tokens != nullptr) {
        *prompt_tokens = prompt_count;
    }
    if (output_tokens != nullptr) {
        *output_tokens = generated;
    }
    if (reached_end_token != nullptr) {
        *reached_end_token = reached_end;
    }
    if (result != 0 && result != 2) {
        set_error(error_buffer, error_buffer_size, error);
    }
    return result;
}

void ipl_llama_cancel(IPLlamaSession * session) {
    if (session != nullptr) {
        session->cancelled.store(true);
    }
}

void ipl_llama_session_destroy(IPLlamaSession * session) {
    if (session == nullptr) {
        return;
    }
    if (session->multimodal != nullptr) {
        mtmd_free(session->multimodal);
    }
    if (session->model != nullptr) {
        llama_model_free(session->model);
    }
    delete session;
}
