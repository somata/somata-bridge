// Generated by CoffeeScript 1.11.1
(function() {
  var BRIDGE_LOCAL, Binding, Bridge, BridgeBinding, BridgeConnection, Connection, EventEmitter, REGISTRY_HOST, REGISTRY_PORT, REGISTRY_PROTO, VERBOSE, argv, bridge, from_port, helpers, minimist, ref, to_addr, zmq,
    extend = function(child, parent) { for (var key in parent) { if (hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; },
    hasProp = {}.hasOwnProperty,
    slice = [].slice;

  zmq = require('zmq');

  EventEmitter = require('events').EventEmitter;

  ref = require('somata'), Binding = ref.Binding, Connection = ref.Connection, helpers = ref.helpers;

  minimist = require('minimist');

  argv = minimist(process.argv);

  VERBOSE = process.env.SOMATA_VERBOSE || false;

  REGISTRY_PROTO = process.env.SOMATA_REGISTRY_PROTO || 'tcp';

  REGISTRY_HOST = process.env.SOMATA_REGISTRY_HOST || '127.0.0.1';

  REGISTRY_PORT = process.env.SOMATA_REGISTRY_PORT || 8420;

  from_port = argv.from || helpers.randomPort();

  to_addr = helpers.parseAddress(argv.to);

  if (!from_port && (to_addr == null)) {
    console.log("Usage: bridge --to [to host]:[to port] --from [from port]");
    console.log("At least one of --to or --from is required");
    process.exit();
  }

  BRIDGE_LOCAL = to_addr != null;

  BridgeConnection = (function(superClass) {
    extend(BridgeConnection, superClass);

    function BridgeConnection() {
      return BridgeConnection.__super__.constructor.apply(this, arguments);
    }

    BridgeConnection.prototype.handleMessage = function(message) {
      if (message.service != null) {
        return this.emit('forward', message);
      } else {
        return BridgeConnection.__super__.handleMessage.apply(this, arguments);
      }
    };

    return BridgeConnection;

  })(Connection);

  BridgeBinding = (function(superClass) {
    extend(BridgeBinding, superClass);

    function BridgeBinding() {
      return BridgeBinding.__super__.constructor.apply(this, arguments);
    }

    BridgeBinding.prototype.forwarded_pings = {};

    BridgeBinding.prototype.handleMessage = function(client_id, message) {
      var ref1;
      if ((ref1 = message.service) != null ? ref1.match('bridge') : void 0) {
        return BridgeBinding.__super__.handleMessage.apply(this, arguments);
      } else {
        if (message.kind === 'ping') {
          if (!this.forwarded_pings[message.id]) {
            this.forwarded_pings[message.id] = true;
            message.ping = 'hello';
          }
        }
        return this.emit('forward', client_id, message);
      }
    };

    return BridgeBinding;

  })(Binding);

  Bridge = (function(superClass) {
    extend(Bridge, superClass);

    Bridge.prototype.service_connections = {};

    Bridge.prototype.service_connection_cbs = {};

    Bridge.prototype.forward_local_services = {};

    Bridge.prototype.reverse_local_services = {};

    Bridge.prototype.forward_remote_services = {};

    Bridge.prototype.reverse_remote_services = {};

    function Bridge() {
      if (to_addr != null) {
        this.createConnection();
      }
      this.createBinding();
      this.connectToRegistry();
    }

    Bridge.prototype.connectToRegistry = function() {
      this.registry_connection = new Connection({
        proto: this.registry_proto || REGISTRY_PROTO,
        host: this.registry_host || REGISTRY_HOST,
        port: this.registry_port || REGISTRY_PORT,
        service: {
          id: 'registry~b',
          name: 'registry'
        }
      });
      this.registry_connection.on('connect', this.connectedToRegistry.bind(this));
      this.registry_connection.subscribe('register', this.registeredService.bind(this));
      return this.registry_connection.subscribe('deregister', this.deregisteredService.bind(this));
    };

    Bridge.prototype.connectedToBridge = function() {
      if (BRIDGE_LOCAL) {
        this.registry_connection.method('findServices', this.foundReverseLocalServices.bind(this));
        return setTimeout((function(_this) {
          return function() {
            return _this.remoteBridgeMethod('findServices', _this.foundForwardRemoteServices.bind(_this));
          };
        })(this), 1000);
      }
    };

    Bridge.prototype.connectedToRegistry = function() {
      if (BRIDGE_LOCAL) {
        return setTimeout((function(_this) {
          return function() {
            return _this.registry_connection.method('findServices', _this.foundReverseLocalServices.bind(_this));
          };
        })(this), 1000);
      } else {
        return setTimeout((function(_this) {
          return function() {
            _this.registry_connection.method('findServices', _this.foundForwardLocalServices.bind(_this));
            return _this.remoteBridgeMethod('findServices', _this.foundReverseRemoteServices.bind(_this));
          };
        })(this), 1000);
      }
    };

    Bridge.prototype.foundForwardLocalServices = function(err, forward_local_services) {
      var service, service_id, service_instances, service_name;
      for (service_name in forward_local_services) {
        service_instances = forward_local_services[service_name];
        for (service_id in service_instances) {
          service = service_instances[service_id];
          if (service.bridge == null) {
            this.forward_local_services[service_id] = service;
          } else {
            delete service_instances[service_id];
          }
        }
      }
      return this.remoteBridgeMethod('registerServices', forward_local_services, function(err, registered) {});
    };

    Bridge.prototype.foundForwardRemoteServices = function(err, forward_remote_services) {
      var forward_remote_service_instances, service, service_id, service_instances, service_name;
      forward_remote_service_instances = [];
      for (service_name in forward_remote_services) {
        service_instances = forward_remote_services[service_name];
        for (service_id in service_instances) {
          service = service_instances[service_id];
          if (service.bridge == null) {
            service.port = from_port;
            service.bridge = 'forward';
            forward_remote_service_instances.push(service);
            this.forward_remote_services[service_id] = service;
          } else {
            helpers.log.w('[foundForwardRemoteServices] Ignore remote bridged', service);
          }
        }
      }
      return this.registry_connection.method('registerServices', forward_remote_service_instances, function() {
        return helpers.log.d('[foundForwardRemoteServices] Registered remote services with local bridge', Object.keys(forward_remote_services));
      });
    };

    Bridge.prototype.foundReverseLocalServices = function(err, reverse_local_services) {
      var service, service_id, service_instances, service_name;
      for (service_name in reverse_local_services) {
        service_instances = reverse_local_services[service_name];
        for (service_id in service_instances) {
          service = service_instances[service_id];
          this.reverse_local_services[service_id] = service;
        }
      }
      return this.remoteBridgeMethod('registerServices', reverse_local_services, function(err, registered) {
        return helpers.log.d('[foundReverseLocalServices] Registered local services with remote bridge', Object.keys(reverse_local_services));
      });
    };

    Bridge.prototype.foundReverseRemoteServices = function(err, reverse_remote_services) {
      var reverse_remote_service_instances, service, service_id, service_instances, service_name;
      reverse_remote_service_instances = [];
      for (service_name in reverse_remote_services) {
        service_instances = reverse_remote_services[service_name];
        for (service_id in service_instances) {
          service = service_instances[service_id];
          if (service.bridge != null) {
            continue;
          }
          this.reverse_remote_services[service_id] = service;
          service.port = from_port;
          service.bridge = 'reverse';
          reverse_remote_service_instances.push(service);
        }
      }
      return this.registry_connection.method('registerServices', reverse_remote_service_instances, function() {
        return helpers.log.d('[handleBridgeMethod.registerServices] Registered local bridge services with local remote registry', Object.keys(reverse_remote_services));
      });
    };

    Bridge.prototype.remoteBridgeMethod = function() {
      var args, cb, handle_response, i, message, method;
      method = arguments[0], args = 3 <= arguments.length ? slice.call(arguments, 1, i = arguments.length - 1) : (i = 1, []), cb = arguments[i++];
      if (cb != null) {
        handle_response = function(response) {
          return cb(response.error, response.response);
        };
      }
      message = {
        service: 'bridge',
        kind: 'method',
        method: method,
        args: args
      };
      if (BRIDGE_LOCAL) {
        return this.sendConnection(message, handle_response);
      } else {
        return this.sendBinding(this.bridged_connection_id, message, handle_response);
      }
    };

    Bridge.prototype.registeredService = function(service) {
      if (service.bridge != null) {
        return;
      }
      if (BRIDGE_LOCAL) {
        service.bridge = 'reverse';
        this.reverse_local_services[service.id] = service;
      } else {
        service.bridge = 'forward';
        this.forward_local_services[service.id] = service;
      }
      return this.remoteBridgeMethod('registerService', service, function(err, registered) {
        return helpers.log.d('[registeredService] Registered local service with remote bridge', service.id);
      });
    };

    Bridge.prototype.deregisteredService = function(service) {
      if (service.bridge != null) {
        return;
      }
      delete this.service_connections[service.id];
      if (BRIDGE_LOCAL) {
        delete this.reverse_local_services[service.id];
      } else {
        delete this.forward_local_services[service.id];
      }
      return this.remoteBridgeMethod('deregisterService', service, function(err, deregistered) {
        return helpers.log.d('[deregisteredService] Deregistered local service with remote bridge', service.id);
      });
    };

    Bridge.prototype.createBinding = function() {
      this.binding = new BridgeBinding({
        host: '0.0.0.0',
        port: from_port
      });
      this.binding.on('method', this.handleBridgeMethod.bind(this));
      return this.binding.on('forward', this.handleBindingForward.bind(this));
    };

    Bridge.prototype.handleReverseBridge = function(message) {
      var instances, service, service_id, service_instances, service_name, services;
      if (message.method === 'registerServices') {
        services = message.args[0];
        instances = [];
        for (service_name in services) {
          service_instances = services[service_name];
          for (service_id in service_instances) {
            service = service_instances[service_id];
            if (service.bridge !== 'reverse') {
              service.port = from_port;
              service.bridge = 'forward';
              this.forward_remote_services[service.id] = service;
              instances.push(service);
            }
          }
        }
        return this.registry_connection.method('registerServices', instances, function() {
          return helpers.log.d('[handleReverseBridge] Registered local bridge service with local remote registry', service.id);
        });
      } else if (message.method === 'registerService') {
        service = message.args[0];
        service.port = from_port;
        service.bridge = 'forward';
        this.forward_remote_services[service.id] = service;
        return this.registry_connection.method('registerService', service, function() {
          return helpers.log.d('[handleReverseBridge] Registered local bridge service with local remote registry', service.id);
        });
      } else if (message.method === 'deregisterService') {
        service = message.args[0];
        delete this.service_connections[service.id];
        delete this.forward_remote_services[service.id];
        return this.registry_connection.method('deregisterService', service.name, service.id, function() {
          return helpers.log.d('[handleReverseBridge] Deregistered local bridge service with local remote registry', service.id);
        });
      }
    };

    Bridge.prototype.handleBridgeMethod = function(connection_id, message) {
      var reverse_remote_service_instances, reverse_remote_services, service, service_id, service_instances, service_name;
      this.bridged_connection_id = connection_id;
      if (message.method === 'findServices') {
        return this.registry_connection.method('findServices', (function(_this) {
          return function(err, forward_local_services) {
            var service, service_id, service_instances, service_name;
            for (service_name in forward_local_services) {
              service_instances = forward_local_services[service_name];
              for (service_id in service_instances) {
                service = service_instances[service_id];
                if (service.bridge == null) {
                  _this.forward_local_services[service_id] = service;
                } else {
                  delete service_instances[service_id];
                }
              }
            }
            return _this.sendBinding(_this.bridged_connection_id, {
              id: message.id,
              kind: 'response',
              response: forward_local_services
            });
          };
        })(this));
      } else if (message.method === 'registerServices') {
        reverse_remote_services = message.args[0];
        reverse_remote_service_instances = [];
        for (service_name in reverse_remote_services) {
          service_instances = reverse_remote_services[service_name];
          for (service_id in service_instances) {
            service = service_instances[service_id];
            if (service.bridge != null) {
              continue;
            }
            this.reverse_remote_services[service_id] = service;
            service.port = from_port;
            service.bridge = 'reverse';
            reverse_remote_service_instances.push(service);
          }
        }
        return this.registry_connection.method('registerServices', reverse_remote_service_instances, function() {
          return helpers.log.d('[handleBridgeMethod.registerServices] Registered local bridge services with local remote registry', Object.keys(reverse_remote_services));
        });
      } else if (message.method === 'registerService') {
        service = message.args[0];
        helpers.log.d('[handleBridgeMethod.registerService]', service);
        if (service.bridge !== 'reverse') {
          return;
        }
        service.port = from_port;
        this.reverse_remote_services[service.id] = service;
        return this.registry_connection.method('registerService', service, function() {
          return helpers.log.d('[handleBridgeMethod.registerService] Registered local bridge service with local remote registry', service.id);
        });
      } else if (message.method === 'deregisterService') {
        service = message.args[0];
        delete this.service_connections[service.id];
        delete this.reverse_remote_services[service.id];
        return this.registry_connection.method('deregisterService', service.name, service.id, function() {
          return helpers.log.d('[handleBridgeMethod.deregisterService] Deregistered local bridge service with local remote registry', service.id);
        });
      }
    };

    Bridge.prototype.handleBindingForward = function(connection_id, message) {
      var connection;
      if (this.forward_local_services[message.service] != null) {
        if (connection = this.getServiceConnection(message.service)) {
          this.service_connection_cbs[message.id] = (function(_this) {
            return function(response) {
              if (_this.reverse_local_services[message.service] != null) {

              } else {
                return _this.sendBinding(connection_id, response);
              }
            };
          })(this);
          return connection.send(JSON.stringify(message));
        } else {
          return helpers.log.e("[handleBindingForward] Couldn't find local service " + message.service);
        }
      } else if (this.forward_remote_services[message.service] != null) {
        return this.sendConnection(message, (function(_this) {
          return function(response_message) {
            return _this.sendBinding(connection_id, response_message);
          };
        })(this));
      } else if (this.reverse_remote_services[message.service] != null) {
        return this.sendBinding(this.bridged_connection_id, message, (function(_this) {
          return function(response_message) {
            return _this.sendBinding(connection_id, response_message);
          };
        })(this));
      } else {
        return helpers.log.e('[handleBindingForward] Not handling', message);
      }
    };

    Bridge.prototype.onBindingMessage = function(connection_id, message_json) {
      var cb, message;
      message = JSON.parse(message_json.toString());
      if (VERBOSE) {
        helpers.log.i("[binding.on message] <" + connection_id + ">", message);
      }
      if (cb = this.binding_cbs[message.id]) {
        return cb(message);
      } else {
        return this.forwardBindingMessageToConnection(connection_id, message);
      }
    };

    Bridge.prototype.createConnection = function() {
      this.connection = new BridgeConnection({
        host: to_addr.host,
        port: to_addr.port,
        service: {
          id: 'bridge~c',
          name: 'bridge'
        }
      });
      this.connection.on('connect', this.connectedToBridge.bind(this));
      return this.connection.on('forward', this.onConnectionMessage.bind(this));
    };

    Bridge.prototype.createServiceConnection = function(service) {
      var connection_socket;
      connection_socket = zmq.socket('dealer');
      connection_socket.identity = helpers.randomString();
      connection_socket.connect(helpers.makeAddress('tcp', service.host, service.port));
      connection_socket.on('message', this.onServiceConnectionMessage.bind(this));
      this.service_connections[service.id] = connection_socket;
      return connection_socket;
    };

    Bridge.prototype.getServiceConnection = function(service_id) {
      var connection, service;
      if (connection = this.service_connections[service_id]) {
        return connection;
      } else {
        if (BRIDGE_LOCAL) {
          if (service = this.reverse_local_services[service_id]) {
            return this.createServiceConnection(service);
          }
        } else {
          if (service = this.forward_local_services[service_id]) {
            return this.createServiceConnection(service);
          }
        }
      }
    };

    Bridge.prototype.onServiceConnectionMessage = function(message_json) {
      var cb, message;
      message_json = message_json.toString();
      message = JSON.parse(message_json);
      if (VERBOSE) {
        helpers.log.i("[service connection.on message]", message);
      }
      if (cb = this.service_connection_cbs[message.id]) {
        return cb(message);
      }
    };

    Bridge.prototype.onConnectionMessage = function(message) {
      var connection, ref1;
      if (VERBOSE) {
        helpers.log.i("[connection.on message]", message);
      }
      if ((ref1 = message.service) != null ? ref1.match(/^bridge/) : void 0) {
        return this.handleReverseBridge(message);
      } else if (message.service != null) {
        if (connection = this.getServiceConnection(message.service)) {
          this.service_connection_cbs[message.id] = (function(_this) {
            return function(response) {
              return _this.sendConnection(response);
            };
          })(this);
          return connection.send(JSON.stringify(message));
        } else {
          return helpers.log.e("[connection.on message] Couldn't find service for " + message.service);
        }
      } else {
        return this.forwardConnectionMessageToBinding(message);
      }
    };

    Bridge.prototype.sendConnection = function(message, cb) {
      var message_json;
      if (VERBOSE) {
        helpers.log.d('[sendConnection]', message);
      }
      message.id || (message.id = helpers.randomString());
      message_json = JSON.stringify(message);
      return this.connection.send(message, cb);
    };

    Bridge.prototype.sendBinding = function(connection_id, message, cb) {
      if (VERBOSE) {
        helpers.log.d("[sendBinding] <" + connection_id + ">", message);
      }
      message.id || (message.id = helpers.randomString());
      return this.binding.send(connection_id, message, cb);
    };

    Bridge.prototype.forwardBindingMessageToConnection = function(connection_id, message) {
      if (VERBOSE) {
        helpers.log.d("[forwardBindingMessageToConnection] <" + connection_id + ">", message);
      }
      return this.sendConnection(message, (function(_this) {
        return function(response_message) {
          return _this.sendBinding(_this.bridged_connection_id, response_message);
        };
      })(this));
    };

    Bridge.prototype.forwardConnectionMessageToBinding = function(message) {
      if (this.bridged_connection_id != null) {
        if (VERBOSE) {
          helpers.log.d("[forwardConnectionMessageToBinding] -> <" + this.bridged_connection_id + ">");
        }
        return setTimeout((function(_this) {
          return function() {
            return _this.sendBinding(_this.bridged_connection_id, message, function(response_message) {
              return _this.sendConnection(response_message);
            });
          };
        })(this), 500);
      } else {
        if (VERBOSE) {
          return helpers.log.e('[forwardConnectionMessageToBinding] no bridged_connection_id');
        }
      }
    };

    return Bridge;

  })(EventEmitter);

  bridge = new Bridge;

}).call(this);