# somata-bridge

Build a bridge between two somata clusters, where one has a port that can be bound to (the "remote" cluster) and one needs only outgoing connections (the "local" cluster). Registered services are shared between clusters, and traffic is forwarded through the single connection created from local to remote.

## Usage

On the remote server use `--from [port]` to bind to a specific port:

```
bridge.coffee --from 5533
```

On the local server use `--to [host]:[port]` to connect to the remote bridge:

```
bridge.coffee --to remote:5533
```
