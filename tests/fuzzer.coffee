# Copyright (c) 2012, Salesforce.com, Inc.  All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.  Redistributions in binary
# form must reproduce the above copyright notice, this list of conditions and
# the following disclaimer in the documentation and/or other materials provided
# with the distribution.  Neither the name of Salesforce.com nor the names of
# its contributors may be used to endorse or promote products derived from this
# software without specific prior written permission.

_       = require('lodash')
async   = require('async')
expect  = require('chai').expect
http    = require('http')
Tandem       = require('tandem-core')
TandemClient = require('./client')
TandemServer = require('../index')

describe('Connection', ->
  httpServer = server = client = null

  before( ->
    httpServer = http.createServer()
    httpServer.listen(9090)
    server = new TandemServer.Server(httpServer)
  )

  after( ->
    httpServer.close()
  )

  getFiles = (numClients, fileId, callback) ->
    async.map([1..numClients], (num, callback) ->
      client = new TandemClient.Client('http://localhost:9090', { latency: _.random(100) })
      file = client.open(fileId)
      file.on(TandemClient.File.events.READY, ->
        expect(file.health).to.equal(TandemClient.File.health.HEALTHY)
        callback(null, file)
      ).on(TandemClient.File.events.ERROR, (error, args...) ->
        console.error(error, args...)
        expect(false).to.be.true
      ).on(TandemClient.File.events.HEALTH, (newHealth) ->
        expect(newHealth).to.equal(TandemClient.File.health.HEALTHY)
      )
    , (err, files) ->
      expect(err).to.equal(null)
      callback(files)
    )

  prepareFuzzer = (numReaders, numWriters, numRooms, callback) ->
    async.map([1..numRooms], (room, callback) ->
      roomId = _.uniqueId('room-')
      getFiles(numReaders, roomId, (readers) ->
        getFiles(numWriters, roomId, (writers) ->
          callback(null, {
            id: roomId
            readers: readers
            writers: writers
          })
        )
      )
    , callback)

  verifyRoom = (room, callback) ->
    files = room.writers.concat(room.readers)
    _.each(files.slice(1), (file) ->
      expect(file.arrived.isEqual(files[0].arrived)).to.be.true
      expect(file.inFlight.isEqual(files[0].inFlight)).to.be.true
      expect(file.inLine.isEqual(files[0].inLine)).to.be.true
      expect(file.version).to.be.equal(files[0].version)
    )
    callback(null)

  fuzz = (numReaders, numWriters, numRooms, numIterations, done) ->
    prepareFuzzer(numReaders, numWriters, numRooms, (err, rooms) ->
      expect(err).to.equal(null)
      async.each(rooms, (room, roomCallback) ->
        async.each(room.writers, (writer, writerCallback) ->
          iterationsLeft = numIterations
          sendUpdate = ->
            delta = Tandem.DeltaGen.getUtils().getRandomDelta(writer.arrived, 1)
            while delta.isIdentity()
              delta = Tandem.DeltaGen.getUtils().getRandomDelta(writer.arrived, 1)
            iterationsLeft -= 1
            if iterationsLeft > 0
              writer.update(delta)
            else
              writerCallback(null)
          writer.sendIfReady = _.wrap(writer.sendIfReady, (wrapper) ->
            ready = !wrapper.call(writer)
            _.defer(sendUpdate) if ready
          )
          sendUpdate()
        , (err) ->
          verifyRoom(room, roomCallback)
        )
      , done)
    )

  it('writer to reader', (done) ->
    this.timeout(20000)
    fuzz(1, 1, 1, 100, done)
  ) 

  it('two writers to reader', (done) ->
    this.timeout(40000)
    fuzz(1, 2, 1, 100, done)
  )

  it('ten rooms of two writers to reader', (done) ->
    this.timeout(400000)
    fuzz(1, 2, 10, 100, done)
  )
)
