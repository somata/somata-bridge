zeromq = require 'zeromq'
{EventEmitter} = require 'events'
{Binding, Connection, helpers} = require 'somata'
minimist = require 'minimist'

# Parse command line arguments

argv = minimist process.argv

VERBOSE = process.env.SOMATA_VERBOSE or false
REGISTRY_PROTO = process.env.SOMATA_REGISTRY_PROTO || 'tcp'
REGISTRY_HOST = process.env.SOMATA_REGISTRY_HOST || '127.0.0.1'
REGISTRY_PORT = process.env.SOMATA_REGISTRY_PORT || 8420

from_port = argv.from or helpers.randomPort()
to_addr = helpers.parseAddress argv.to
if !from_port and !to_addr?
    console.log "Usage: bridge --to [to host]:[to port] --from [from port]"
    console.log "At least one of --to or --from is required"
    process.exit()

BRIDGE_LOCAL = to_addr?

# Extend connection and binding to forward messages through bridge

class BridgeConnection extends Connection
    handleMessage: (message) ->
        if message.service?
            @emit 'forward', message
        else
            super(message)

class BridgeBinding extends Binding
    forwarded_pings: {}

    handleMessage: (client_id, message) ->
        if message.service?.match 'bridge'
            super()
        else
            if message.kind == 'ping'
                # Manipulate to be hello
                if !@forwarded_pings[message.id]
                    @forwarded_pings[message.id] = true
                    message.ping = 'hello'

            @emit 'forward', client_id, message

class Bridge extends EventEmitter
    service_connections: {}
    service_connection_cbs: {}

    forward_local_services: {}
    reverse_local_services: {}
    forward_remote_services: {}
    reverse_remote_services: {}

    constructor: ->
        super()
        if to_addr?
            @createConnection()
        @createBinding()
        @connectToRegistry()

    # Send local registry info with remote bridge

    connectToRegistry: ->
        @registry_connection = new Connection
            proto: @registry_proto or REGISTRY_PROTO
            host: @registry_host or REGISTRY_HOST
            port: @registry_port or REGISTRY_PORT
            service: {id: 'registry~b', name: 'registry'}
        @registry_connection.on 'connect', @connectedToRegistry.bind(@)
        @registry_connection.subscribe 'register', @registeredService.bind(@)
        @registry_connection.subscribe 'deregister', @deregisteredService.bind(@)

    connectedToBridge: ->
        if BRIDGE_LOCAL
            @registry_connection.method 'findServices', @foundReverseLocalServices.bind(@)
            # Ask remote bridge for registry info
            setTimeout =>
                @remoteBridgeMethod 'findServices', @foundForwardRemoteServices.bind(@)
            , 1000

    connectedToRegistry: ->
        if BRIDGE_LOCAL
            # Get local registry info and send to remote bridge
            setTimeout =>
                @registry_connection.method 'findServices', @foundReverseLocalServices.bind(@)
            , 1000
        else
            setTimeout =>
                @registry_connection.method 'findServices', @foundForwardLocalServices.bind(@)
                @remoteBridgeMethod 'findServices', @foundReverseRemoteServices.bind(@)
            , 1000

    foundForwardLocalServices: (err, forward_local_services) ->
        for service_name, service_instances of forward_local_services
            for service_id, service of service_instances
                if !service.bridge?
                    @forward_local_services[service_id] = service
                else
                    delete service_instances[service_id]

        @remoteBridgeMethod 'registerServices', forward_local_services, (err, registered) ->

    foundForwardRemoteServices: (err, forward_remote_services) ->
        forward_remote_service_instances = []
        for service_name, service_instances of forward_remote_services
            for service_id, service of service_instances
                if !service.bridge?
                    service.port = from_port
                    service.bridge = 'forward'
                    forward_remote_service_instances.push service
                    @forward_remote_services[service_id] = service
                else
                    helpers.log.w '[foundForwardRemoteServices] Ignore remote bridged', service

        @registry_connection.method 'registerServices', forward_remote_service_instances, ->
            helpers.log.d '[foundForwardRemoteServices] Registered remote services with local bridge', Object.keys forward_remote_services

    foundReverseLocalServices: (err, reverse_local_services) ->
        for service_name, service_instances of reverse_local_services
            for service_id, service of service_instances
                @reverse_local_services[service_id] = service
        @remoteBridgeMethod 'registerServices', reverse_local_services, (err, registered) ->
            helpers.log.d '[foundReverseLocalServices] Registered local services with remote bridge', Object.keys reverse_local_services

    foundReverseRemoteServices: (err, reverse_remote_services) ->
        reverse_remote_service_instances = []
        for service_name, service_instances of reverse_remote_services
            for service_id, service of service_instances
                continue if service.bridge?
                @reverse_remote_services[service_id] = service
                service.port = from_port
                service.bridge = 'reverse'
                reverse_remote_service_instances.push service
        @registry_connection.method 'registerServices', reverse_remote_service_instances, ->
            helpers.log.d '[handleBridgeMethod.registerServices] Registered local bridge services with local remote registry', Object.keys reverse_remote_services

    remoteBridgeMethod: (method, args..., cb) ->
        if cb? then handle_response = (response) -> cb response.error, response.response
        message = {service: 'bridge', kind: 'method', method, args}
        if BRIDGE_LOCAL
            @sendConnection message, handle_response
        else
            @sendBinding @bridged_connection_id, message, handle_response

    registeredService: (service) ->
        return if service.bridge?

        if BRIDGE_LOCAL
            service.bridge = 'reverse'
            @reverse_local_services[service.id] = service
        else
            service.bridge = 'forward'
            @forward_local_services[service.id] = service
        @remoteBridgeMethod 'registerService', service, (err, registered) ->
            helpers.log.d '[registeredService] Registered local service with remote bridge', service.id

    deregisteredService: (service) ->
        return if service.bridge?

        delete @service_connections[service.id]
        if BRIDGE_LOCAL
            delete @reverse_local_services[service.id]
        else
            delete @forward_local_services[service.id]
        @remoteBridgeMethod 'deregisterService', service, (err, deregistered) ->
            helpers.log.d '[deregisteredService] Deregistered local service with remote bridge', service.id

    # Binding accepts local connections, forwards through bridge connection to
    # remote bridge binding

    createBinding: ->
        @binding = new BridgeBinding {host: '0.0.0.0', port: from_port}
        @binding.on 'method', @handleBridgeMethod.bind(@)
        @binding.on 'forward', @handleBindingForward.bind(@)

    handleReverseBridge: (message) ->
        if message.method == 'registerServices'
            services = message.args[0]
            instances = []
            for service_name, service_instances of services
                for service_id, service of service_instances
                    if service.bridge != 'reverse'
                        service.port = from_port
                        service.bridge = 'forward'
                        @forward_remote_services[service.id] = service
                        instances.push service

            @registry_connection.method 'registerServices', instances, ->
                helpers.log.d '[handleReverseBridge] Registered local bridge service with local remote registry', service.id

        else if message.method == 'registerService'
            service = message.args[0]
            service.port = from_port
            service.bridge = 'forward'
            @forward_remote_services[service.id] = service
            @registry_connection.method 'registerService', service, ->
                helpers.log.d '[handleReverseBridge] Registered local bridge service with local remote registry', service.id

        else if message.method == 'deregisterService'
            service = message.args[0]
            delete @service_connections[service.id]
            delete @forward_remote_services[service.id]
            @registry_connection.method 'deregisterService', service.name, service.id, ->
                helpers.log.d '[handleReverseBridge] Deregistered local bridge service with local remote registry', service.id

    handleBridgeMethod: (connection_id, message) ->
        @bridged_connection_id = connection_id

        # Local bridge finding remote services
        if message.method == 'findServices'
            @registry_connection.method 'findServices', (err, forward_local_services) =>
                for service_name, service_instances of forward_local_services
                    for service_id, service of service_instances
                        if !service.bridge?
                            @forward_local_services[service_id] = service
                        else
                            delete service_instances[service_id]

                @sendBinding @bridged_connection_id, {id: message.id, kind: 'response', response: forward_local_services}

        # Local bridge sending local services
        else if message.method == 'registerServices'
            reverse_remote_services = message.args[0]
            reverse_remote_service_instances = []
            for service_name, service_instances of reverse_remote_services
                for service_id, service of service_instances
                    continue if service.bridge?
                    @reverse_remote_services[service_id] = service
                    service.port = from_port
                    service.bridge = 'reverse'
                    reverse_remote_service_instances.push service
            @registry_connection.method 'registerServices', reverse_remote_service_instances, ->
                helpers.log.d '[handleBridgeMethod.registerServices] Registered local bridge services with local remote registry', Object.keys reverse_remote_services

        else if message.method == 'registerService'
            service = message.args[0]
            helpers.log.d '[handleBridgeMethod.registerService]', service
            return if service.bridge != 'reverse'
            service.port = from_port
            @reverse_remote_services[service.id] = service
            @registry_connection.method 'registerService', service, ->
                helpers.log.d '[handleBridgeMethod.registerService] Registered local bridge service with local remote registry', service.id

        else if message.method == 'deregisterService'
            service = message.args[0]

            delete @service_connections[service.id]
            delete @reverse_remote_services[service.id]
            @registry_connection.method 'deregisterService', service.name, service.id, ->
                helpers.log.d '[handleBridgeMethod.deregisterService] Deregistered local bridge service with local remote registry', service.id

    # Reverse method call from remote connection to local service
    handleBindingForward: (connection_id, message) ->
        if @forward_local_services[message.service]?
            if connection = @getServiceConnection message.service
                @service_connection_cbs[message.id] = (response) =>
                    if @reverse_local_services[message.service]?
                        # @sendBinding connection_id, response
                    else
                        @sendBinding connection_id, response
                connection.send JSON.stringify message
            else
                helpers.log.e "[handleBindingForward] Couldn't find local service #{message.service}"
        else if @forward_remote_services[message.service]?
            @sendConnection message, (response_message) =>
                @sendBinding connection_id, response_message
        else if @reverse_remote_services[message.service]?
            @sendBinding @bridged_connection_id, message, (response_message) =>
                @sendBinding connection_id, response_message
        else
            helpers.log.e '[handleBindingForward] Not handling', message

    onBindingMessage: (connection_id, message_json) ->
        # TODO: There will be multiple connections to a binding, need
        # connection id per incoming messages for penidng callbacks
        message = JSON.parse message_json.toString()
        helpers.log.i "[binding.on message] <#{connection_id}>", message if VERBOSE

        if cb = @binding_cbs[message.id]
            cb(message)

        else
            @forwardBindingMessageToConnection connection_id, message

    # Outgoing connection to remote bridge, forwards messages and accepts
    # messages from remote binding to forward back through bridge binding to
    # local connection

    createConnection: ->
        @connection = new BridgeConnection
            host: to_addr.host
            port: to_addr.port
            service: {id: 'bridge~c', name: 'bridge'}
        @connection.on 'connect', @connectedToBridge.bind(@)
        @connection.on 'forward', @onConnectionMessage.bind(@)

    createServiceConnection: (service) ->
        connection_socket = zeromq.socket 'dealer'
        connection_socket.identity = helpers.randomString()
        connection_socket.connect helpers.makeAddress 'tcp', service.host, service.port

        # Forward messages from remote binding to own binding to local connection
        connection_socket.on 'message', @onServiceConnectionMessage.bind(@)
        @service_connections[service.id] = connection_socket
        return connection_socket

    getServiceConnection: (service_id) ->
        if connection = @service_connections[service_id]
            return connection
        else
            if BRIDGE_LOCAL
                if service = @reverse_local_services[service_id]
                    return @createServiceConnection(service)
            else
                if service = @forward_local_services[service_id]
                    return @createServiceConnection(service)

    onServiceConnectionMessage: (message_json) ->
        message_json = message_json.toString()
        message = JSON.parse message_json
        helpers.log.i "[service connection.on message]", message if VERBOSE

        if cb = @service_connection_cbs[message.id]
            cb(message)

    onConnectionMessage: (message) ->
        helpers.log.i "[connection.on message]", message if VERBOSE

        if message.service?.match /^bridge/
            @handleReverseBridge(message)

        # Forwarding to a specific service
        else if message.service?
            if connection = @getServiceConnection(message.service)
                @service_connection_cbs[message.id] = (response) =>
                    @sendConnection response
                connection.send JSON.stringify message

            else
                helpers.log.e "[connection.on message] Couldn't find service for #{message.service}"

        else
            @forwardConnectionMessageToBinding message

    # Sending messages and storing callbacks

    sendConnection: (message, cb) ->
        helpers.log.d '[sendConnection]', message if VERBOSE
        message.id ||= helpers.randomString()
        message_json = JSON.stringify message
        @connection.send message, cb

    sendBinding: (connection_id, message, cb) ->
        helpers.log.d "[sendBinding] <#{connection_id}>", message if VERBOSE
        message.id ||= helpers.randomString()
        @binding.send connection_id, message, cb

    forwardBindingMessageToConnection: (connection_id, message) ->
        helpers.log.d "[forwardBindingMessageToConnection] <#{connection_id}>", message if VERBOSE
        @sendConnection message, (response_message) =>
            @sendBinding @bridged_connection_id, response_message

    forwardConnectionMessageToBinding: (message) ->
        if @bridged_connection_id?
            helpers.log.d "[forwardConnectionMessageToBinding] -> <#{@bridged_connection_id}>" if VERBOSE
            setTimeout =>
                @sendBinding @bridged_connection_id, message, (response_message) =>
                    @sendConnection response_message
            , 500
        else
            helpers.log.e '[forwardConnectionMessageToBinding] no bridged_connection_id' if VERBOSE

bridge = new Bridge
