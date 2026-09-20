#ifndef INFERPEER_LLAMA_BRIDGE_H
#define INFERPEER_LLAMA_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IPLlamaSession IPLlamaSession;

typedef void (*IPLLamaTokenCallback)(
    const char * bytes,
    int32_t byte_count,
    void * context
);

IPLlamaSession * ipl_llama_session_create(
    const char * model_path,
    const char * projector_path,
    uint32_t context_tokens,
    int32_t gpu_layers,
    char * error_buffer,
    size_t error_buffer_size
);

bool ipl_llama_session_supports_vision(const IPLlamaSession * session);

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
);

void ipl_llama_cancel(IPLlamaSession * session);
void ipl_llama_session_destroy(IPLlamaSession * session);

#ifdef __cplusplus
}
#endif

#endif
