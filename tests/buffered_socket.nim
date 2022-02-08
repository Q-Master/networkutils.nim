import unittest
import std/[asyncdispatch, net]
import networkutils/buffered_socket

const BUF_SIZE = 10

suite "Socket connection":
  setup:
    discard

  test "Simple async socket test":
    proc server() {.async.} =
      var sock = newAsyncBufferedSocket(bufSize = BUF_SIZE)
      sock.setSockOpt(OptReuseAddr, true)
      sock.bindAddr(Port(16161))
      sock.listen()
      let client = await sock.accept()
      let str = await client.recvLine()
      check(str == "CHECK the Socket")
      await sleepAsync(300)
      await client.sendLine("CHECK complete even if the string is larger than the buffer")
      await sleepAsync(300)
      client.close()
      sock.close()

    proc testConnection() {.async} =
      asyncCheck(server())
      var sock = newAsyncBufferedSocket(bufSize = BUF_SIZE)
      await sock.connect("localhost", Port(16161))
      await sock.sendLine("CHECK the Socket")
      let replStr = await sock.recvLine()
      check(replStr == "CHECK complete even if the string is larger than the buffer")
      sock.close()
    waitFor(testConnection())
