zmq = require 'zmq'
{EventEmitter} = require 'events'
{Binding, Connection, helpers} = require 'somata'
util = require 'util'

REGISTRY_PROTO = process.env.SOMATA_REGISTRY_PROTO || 'tcp'
REGISTRY_HOST = process.env.SOMATA_REGISTRY_HOST || '127.0.0.1'
REGISTRY_PORT = process.env.SOMATA_REGISTRY_PORT || 8420
BRIDGE_LOCAL = parseInt process.env.BRIDGE_LOCAL or 0

from_port = parseInt process.argv[2]
to_addr = helpers.parseAddress process.argv[3]
if !from_port or !to_addr?.host or !to_addr?.port
    console.log "Usage: bridge [from port] [to addr]"
    process.exit()

bridged_connection_id = null

class Connection2 extends Connection
    handleMessage: (message) ->
        if message.service?
            @emit 'forward', message
        else
            super

class Binding2 extends Binding
    forwarded_pings: {}

    handleMessage: (client_id, message) ->
        if message.service?.match 'bridge'
            super
        else
            if message.kind == 'ping'
                # Manipulate to be hello
                if !@forwarded_pings[message.id]
                    @forwarded_pings[message.id] = true
                    message.ping = 'hello'

            @emit 'forward', client_id, message

class Bridge extends EventEmitter
    service_connections: {}
    connection_cbs: {}
    service_connection_cbs: {}
    # registry_connection
    # remote_bridge_connection
    # local_bridge_binding

    forward_local_services: {}
    reverse_local_services: {}
    forward_remote_services: {}
    reverse_remote_services: {}

    constructor: ->
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
        @registry_connection.subscribe 'register', @registeredService.bind(@)
        @registry_connection.subscribe 'deregister', @deregisteredService.bind(@)

    connectedToBridge: ->

        if BRIDGE_LOCAL
            # Ask remote bridge for registry info
            @remoteBridgeMethod 'findServices', @foundRemoteServices.bind(@)

            # Get local registry info and send to remote bridge
            @registry_connection.method 'findServices', @foundLocalServices.bind(@)

    foundRemoteServices: (err, remote_services) ->
        remote_service_instances = []
        for service_name, service_instances of remote_services
            for service_id, service of service_instances
                if !service.bridge?
                    service.port = from_port
                    service.bridge = 'forward'
                    remote_service_instances.push service
                    @forward_remote_services[service_id] = service
                else
                    helpers.log.w '[foundRemoteServices] Ignore remote bridged', service
        @registry_connection.method 'registerServices', remote_service_instances, ->
            helpers.log.d '[foundRemoteServices] Registered remote services with local bridge', Object.keys remote_services

    foundLocalServices: (err, local_services) ->
        for service_name, service_instances of local_services
            for service_id, service of service_instances
                @reverse_local_services[service_id] = service
        @remoteBridgeMethod 'registerServices', local_services, (err, registered) ->
            helpers.log.d '[foundLocalServices] Registered local services with remote bridge', Object.keys local_services

    remoteBridgeMethod: (method, args..., cb) ->
        if cb? then handle_response = (response) -> cb response.error, response.response
        message = {service: 'bridge', kind: 'method', method, args}
        if BRIDGE_LOCAL
            @sendConnection message, handle_response
        else
            @sendBinding bridged_connection_id, message, handle_response

    registeredService: (err, service) ->
        return if service.bridge?

        if BRIDGE_LOCAL
            service.bridge = 'reverse'
            @reverse_local_services[service.id] = service
        else
            service.bridge = 'forward'
            @forward_local_services[service.id] = service
        @remoteBridgeMethod 'registerService', service, (err, registered) ->
            helpers.log.d '[registeredService] Registered local service with remote bridge', service.id

    deregisteredService: (err, service) ->
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
        # @binding_socket = zmq.socket 'router'
        # @binding_socket.bindSync helpers.makeAddress 'tcp', '0.0.0.0', from_port
        # @binding_socket.on 'message', @onBindingMessage.bind(@)
        @binding = new Binding2 {host: '0.0.0.0', port: from_port}
        @binding.on 'method', @handleBridgeMethod.bind(@)
        @binding.on 'forward', @handleBindingForward.bind(@)

    handleReverseBridge: (message) ->
        if message.method == 'registerService'
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
        bridged_connection_id = connection_id

        # Local bridge finding remote services
        if message.method == 'findServices'
            @registry_connection.method 'findServices', (err, services) =>
                for service_name, service_instances of services
                    for service_id, service of service_instances
                        if !service.bridge?
                            @forward_local_services[service_id] = service
                @sendBinding bridged_connection_id, {id: message.id, kind: 'response', response: services}

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
                connection.send JSON.stringify message
                @service_connection_cbs[message.id] = (response) =>
                    if @reverse_local_services[message.service]?
                        # @sendBinding connection_id, response
                    else
                        @sendBinding connection_id, response
            else
                helpers.log.e "[handleBindingForward] Couldn't find local service #{message.service}"
        else if @forward_remote_services[message.service]?
            @sendConnection message, (response_message) =>
                @sendBinding connection_id, response_message
        else if @reverse_remote_services[message.service]?
            @sendBinding bridged_connection_id, message, (response_message) =>
                @sendBinding connection_id, response_message
        else
            helpers.log.e '[handleBindingForward] Not handling', message

    onBindingMessage: (connection_id, message_json) ->
        # TODO: There will be multiple connections to a binding, need
        # connection id per incoming messages for penidng callbacks
        message = JSON.parse message_json.toString()
        helpers.log.i "[binding.on message] <#{connection_id}>", message

        if cb = @binding_cbs[message.id]
            cb(message)

        else
            @forwardBindingMessageToConnection connection_id, message

    # Outgoing connection to remote bridge, forwards messages and accepts
    # messages from remote binding to forward back through bridge binding to
    # local connection

    createConnection: ->
        @connection = new Connection2
            host: to_addr.host
            port: to_addr.port
            service: {id: 'bridge~c', name: 'bridge'}
        @connection.on 'connect', @connectedToBridge.bind(@)
        @connection.on 'forward', @onConnectionMessage.bind(@)

    createServiceConnection: (service) ->
        connection_socket = zmq.socket 'dealer'
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
        helpers.log.i "[service connection.on message]", message

        if cb = @service_connection_cbs[message.id]
            cb(message)

    onConnectionMessage: (message) ->
        helpers.log.i "[connection.on message]", message

        if cb = @connection_cbs[message.id]
            cb(message)

        else if message.service?.match /^bridge/
            @handleReverseBridge(message)

        # Forwarding to a specific service
        else if message.service?
            if connection = @getServiceConnection(message.service)
                connection.send JSON.stringify message
                @service_connection_cbs[message.id] = (response) =>
                    @sendConnection response

            else
                helpers.log.e "[connection.on message] Couldn't find service for #{message.service}"

        else
            @forwardConnectionMessageToBinding message

    # Sending messages and storing callbacks

    sendConnection: (message, cb) ->
        helpers.log.d '[sendConnection]', message
        message.id ||= helpers.randomString()
        message_json = JSON.stringify message
        # if cb?
        #     @connection_cbs[message.id] = cb
        # # @connection_socket.send message_json
        @connection.send message, cb

    sendBinding: (connection_id, message, cb) ->
        helpers.log.d "[sendBinding] <#{connection_id}>", message
        message.id ||= helpers.randomString()
        # message_json = JSON.stringify message
        @binding.send connection_id, message, cb

    forwardBindingMessageToConnection: (connection_id, message) ->
        helpers.log.d "[forwardBindingMessageToConnection] <#{connection_id}>", message
        @sendConnection message, (response_message) =>
            @sendBinding bridged_connection_id, response_message

    forwardConnectionMessageToBinding: (message) ->
        if bridged_connection_id?
            helpers.log.d "[forwardConnectionMessageToBinding] -> <#{bridged_connection_id}>"
            setTimeout =>
                @sendBinding bridged_connection_id, message, (response_message) =>
                    @sendConnection response_message
            , 500
        else
            helpers.log.e '[forwardConnectionMessageToBinding] no bridged_connection_id'

bridge = new Bridge
