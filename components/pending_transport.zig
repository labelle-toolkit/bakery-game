/// Tracks a pending EOS-to-EIS transport on an EOS storage entity.
/// Replaces the pending_transports HashMap in eos_transport.zig.
/// Set on: EOS entities when transport is assigned.
/// Removed when: transport completes or is cancelled.
pub const PendingTransport = struct {
    target_eis: u64,
};
