import unittest
import std/[asyncdispatch, net]
import networkutils/buffered_socket

const BUF_SIZE = 10

suite "Socket connection":
  setup:
    discard

  test "Simple async socket test":
    proc server() {.async.} =
      var sock = newAsyncBufferedSocket(inBufSize = BUF_SIZE)
      sock.setSockOpt(OptReuseAddr, true)
      sock.bindAddr(Port(16161))
      sock.listen()
      let client = await sock.accept()
      let str = await client.recvLine()
      check(str == "CHECK the Socket")
      await client.sendLine("CHECK complete even if the string is larger than the buffer")
      await client.close()
      await sock.close()

    proc testConnection() {.async} =
      asyncCheck(server())
      var sock = newAsyncBufferedSocket(inBufSize = BUF_SIZE)
      await sock.connect("localhost", Port(16161))
      await sock.sendLine("CHECK the Socket")
      let replStr = await sock.recvLine()
      check(replStr == "CHECK complete even if the string is larger than the buffer")
      await sock.close()
    waitFor(testConnection())

  test "Simple async socket buffered test":
    proc server() {.async.} =
      var sock = newAsyncBufferedSocket(inBufSize = BUF_SIZE, outBufSize = BUF_SIZE)
      sock.setSockOpt(OptReuseAddr, true)
      sock.bindAddr(Port(16161))
      sock.listen()
      let client = await sock.accept()
      let str = await client.recvLine()
      check(str == "CHECK the Socket")
      await client.sendLine("CHECK complete even if the string is larger than the buffer")
      await sock.flush()
      await client.close()
      await sock.close()

    proc testConnection() {.async} =
      asyncCheck(server())
      var sock = newAsyncBufferedSocket(inBufSize = BUF_SIZE, outBufSize = BUF_SIZE)
      await sock.connect("localhost", Port(16161))
      await sock.sendLine("CHECK the Socket")
      await sock.flush()
      let replStr = await sock.recvLine()
      check(replStr == "CHECK complete even if the string is larger than the buffer")
      await sock.close()
    waitFor(testConnection())
