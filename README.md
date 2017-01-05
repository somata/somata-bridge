# Somata Bridge

Build a bridge between two [Somata](https://github.com/somata/somata-node) servers, where one has a port that can be bound to (the "remote" server) and one needs only outgoing connections (the "local" server). Registered services are shared between servers, and traffic is forwarded through the connection between the bridges.

## Installation

Install globally with NPM. See [Somata installation](https://github.com/somata/somata-node#installation) for more.

```sh
$ npm install -g somata-bridge
```

## Usage

On the remote server use `--from [port]` to bind to a specific port:

```
somata-bridge --from 5533
```

On the local server use `--to [host]:[port]` to connect to the remote bridge:

```
somata-bridge --to remote:5533
```
