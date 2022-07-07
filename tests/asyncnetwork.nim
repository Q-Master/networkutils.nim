import unittest
import std/[asyncdispatch, net, asyncnet]
import networkutils/asyncnetwork

let checkTheSocket: string = "CHECK the Socket"

suite "Async networking operations":
  setup:
    discard

  test "Simple async socket without timeout test":
    proc server() {.async.} =
      var sock = newAsyncSocket(buffered = false)
      sock.setSockOpt(OptReuseAddr, true)
      sock.bindAddr(Port(16161))
      sock.listen()
      let client = await sock.accept()
      var receivedStr: string
      receivedStr.setLen(checkTheSocket.len)
      let receivedLen = await client.recvInto(receivedStr[0].addr, receivedStr.len, 1000)
      check(receivedLen == checkTheSocket.len)
      check(receivedStr == checkTheSocket)
      client.close()
      sock.close()

    proc testConnection() {.async.} =
      let f = server()
      var sock = newAsyncSocket(buffered = false)
      await sock.connect("localhost", Port(16161))
      await sock.send(checkTheSocket[0].unsafeAddr, checkTheSocket.len)
      sock.close()
      await f
    waitFor(testConnection())

  test "Simple async socket with timeout test":
    proc server() {.async.} =
      var sock = newAsyncSocket(buffered = false)
      sock.setSockOpt(OptReuseAddr, true)
      sock.bindAddr(Port(16161))
      sock.listen()
      let client = await sock.accept()
      var receivedStr: string
      receivedStr.setLen(checkTheSocket.len)
      var receivedLen: int = 0
      expect TimeoutError:
        receivedLen = await client.recvInto(receivedStr[0].addr, receivedStr.len, 500)
      try:
        receivedLen = await client.recvInto(receivedStr[0].addr, receivedStr.len, 1000)
      except TimeoutError:
        fail()
      check(receivedLen == checkTheSocket.len)
      check(receivedStr == checkTheSocket)
      client.close()
      sock.close()

    proc testConnection() {.async.} =
      let f = server()
      var sock = newAsyncSocket(buffered = false)
      await sock.connect("localhost", Port(16161))
      await sleepAsync(1000)
      await sock.send(checkTheSocket[0].unsafeAddr, checkTheSocket.len)
      sock.close()
      await f
    waitFor(testConnection())
