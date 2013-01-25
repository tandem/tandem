checkAdapterError = (response, callback) ->
  if !response.error? or response.error.length == 0
    callback.call(this, response)
  else
    this.emit(TandemFile.events.ERROR, response.error)

initAdapterListeners = ->
  @adapter.on(TandemFile.routes.UPDATE, (packet) =>
    unless @engine.remoteUpdate(packet.delta, packet.version)
      console.warn "Remote update failed, requesting resync"
      resync.call(this)
  ).on(TandemFile.routes.JOIN, (packet) =>
    this.emit(TandemFile.events.JOIN, packet)
  ).on(TandemFile.routes.LEAVE, (packet) =>
    this.emit(TandemFile.events.LEAVE, packet)
  )

initEngine = (initial, version) ->
  @engine = new Tandem.ClientEngine(initial, version, (delta, version, callback) =>
    sendUpdate.call(this, delta, version, callback)
  )

initEngineListeners = ->
  @engine.on(Tandem.ClientEngine.events.UPDATE, (delta) =>
    this.emit(TandemFile.events.UPDATE, delta)
  ).on(Tandem.ClientEngine.events.ERROR, (args...) =>
    this.emit(TandemFile.events.ERROR, this, args)
    console.warn "Engine error, attempting resync", @id, args
    resync.call(this)
  )

initHealthListeners = ->
  @adapter.on(Tandem.NetworkAdapter.events.READY, =>
    this.emit(TandemFile.events.HEALTH, @health, TandemFile.health.HEALTHY)
    sync.call(this)
  ).on(Tandem.NetworkAdapter.events.RECONNECT, (transport, attempts) =>
    sync.call(this)
  ).on(Tandem.NetworkAdapter.events.RECONNECTING, (timeout, attempts) =>
    this.emit(TandemFile.events.HEALTH, @health, TandemFile.health.ERROR) if attempts == 1
  ).on(Tandem.NetworkAdapter.events.DISCONNECT, =>
    this.emit(TandemFile.events.HEALTH, @health, TandemFile.health.ERROR)
  ).on(Tandem.NetworkAdapter.events.ERROR, (args...) =>
    this.emit(TandemFile.events.ERROR, this, args)
    this.emit(TandemFile.events.HEALTH, @health, TandemFile.health.ERROR)
  )
  this.on(TandemFile.events.HEALTH, (oldHealth, newHealth) =>
    @health = newHealth
  )

initListeners = ->
  initAdapterListeners.call(this)
  initEngineListeners.call(this)
  initHealthListeners.call(this)

resync = ->
  this.emit(TandemFile.events.HEALTH, @health, TandemFile.health.WARNING)
  this.send(TandemFile.routes.RESYNC, {}, (response) =>
    delta = Tandem.Delta.makeDelta(response.head)
    @engine.resync(delta, response.version)
    this.emit(TandemFile.events.HEALTH, @health, TandemFile.health.HEALTHY)
  )

sendUpdate = (delta, version, callback) ->
  packet = { delta: delta, version: version }
  this.send(Tandem.File.routes.UPDATE, packet, (response) =>
    if response.resync
      console.warn "Update requesting resync", @id, packet, response
      delta = Tandem.Delta.makeDelta(response.head)
      @engine.resync(delta, response.version)
      sendUpdate.call(this, @engine.inFlight, @engine.version, callback)
    else
      callback.call(this, response)
  )

sync = ->
  this.emit(TandemFile.events.HEALTH, @health, TandemFile.health.HEALTHY)
  this.send(TandemFile.routes.SYNC, { version: @engine.version }, (response) =>
    if response.resync
      console.warn "Sync requesting resync"
      resync.call(this)
    else
      unless @engine.remoteUpdate(response.delta, response.version)
        console.warn "Remote update failed on sync, requesting resync"
        resync.call(this)
    this.emit(TandemFile.events.READY)
  , true)


class TandemFile extends EventEmitter2
  @events:
    ERROR   : 'file-error'
    HEALTH  : 'file-health'
    JOIN    : 'file-join'
    LEAVE   : 'file-leave'
    READY   : 'file-ready'
    UPDATE  : 'file-update'

  @health:
    HEALTHY : 'healthy' 
    WARNING : 'warning'
    ERROR   : 'error'

  @routes:
    JOIN    : 'user/join'
    LEAVE   : 'user/leave'
    RESYNC  : 'ot/resync'
    SYNC    : 'ot/sync'
    UPDATE  : 'ot/update'

  constructor: (@fileId, @adapter, initial, version) ->
    @id = _.uniqueId('file-')
    @health = TandemFile.health.WARNING
    initEngine.call(this, initial, version)
    initListeners.call(this)

  close: ->
    @adapter.removeAllListeners()
    @engine.removeAllListeners()

  getUsers: ->
    return []

  isDirty: ->
    return !@engine.inFlight.isIdentity() or !@engine.inLine.isIdentity()

  send: (route, packet, callback, priority = false) ->
    @adapter.send(route, packet, (response) =>
      checkAdapterError.call(this, response, callback)
    , priority)

  transform: (indexes) ->
    @engine.transform(indexes)

  update: (delta) ->
    @engine.localUpdate(delta)


Tandem.File = TandemFile
