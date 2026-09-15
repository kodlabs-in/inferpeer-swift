# Security

InferPeer is an experimental local-network package. Report suspected vulnerabilities privately to
the repository owner; do not include pairing secrets, certificates, prompts, generated text, or
device identifiers in a public issue.

## Security boundary

- gRPC sessions use mutual TLS and bind the authenticated certificate identity to the session.
- Pairing invitations expire, are single-use at the issuing coordinator, and pin the coordinator
  certificate fingerprint.
- Trust is scoped by caller or worker role. Revocation blocks future sessions and asks the active
  coordinator to terminate the peer.
- Bonjour results are untrusted discovery candidates. Numeric endpoints and sockets are restricted
  to the configured Wi-Fi interface and private, link-local, or unique-local address space.
- Request ownership and allowed-worker policy are checked before replay or execution.
- Request and event sizes, stream buffers, queue depth, database content, attempts, leases, and
  deadlines are bounded.

## Host responsibilities

The embedding app must obtain explicit pairing approval, provide local-network usage descriptions,
forward foreground/background participation changes, choose non-synchronising Keychain storage,
and place application databases and model files outside cloud-synchronised locations. Apply file
protection and backup-exclusion settings appropriate to the app's threat model.

InferPeer does not log prompts, generated output, credentials, or invitation proofs. Hosts must
apply the same redaction rule to their own logs and must explain that an approved worker receives
the readable request content it executes.

## Validation boundary

Automated tests cover certificate identity checks, role-scoped trust, invitation expiry and atomic
single use, revocation, LAN endpoint policy, bounded messages, ownership, and replay authorization.
Packet capture, physical-device lifecycle behavior, Keychain entitlement behavior, and host backup
configuration remain manual release gates for the sandbox app.
