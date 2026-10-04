# Weft

A collaborative terminal text editor written in Zig, using [Vaxis](https://github.com/rockorager/libvaxis) and [crdt.zig](https://github.com/braheezy/crdt.zig). Edit offline and synchronize with a peer over TCP.

## Usage

```sh
zig build run
```

To collaborate, run these commands in separate terminals:

```sh
zig build run -- --listen 127.0.0.1:9000 --session alice.crdt
zig build run -- --connect 127.0.0.1:9000 --session bob.crdt
```

Use a separate session file for each peer and the same `--document NAME` (default: `shared`). Session files preserve the document, actor identity, and edit history across restarts. For remote peers, use a trusted LAN or Tailscale address.

Arrow keys, Home, and End move the cursor. Ctrl-O toggles networking, Ctrl-S saves, and Ctrl-Q quits.

## Development

```sh
zig build
zig build test
```
