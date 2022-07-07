import unittest
import std/[asyncdispatch, net]
import networkutils/buffered_socket

const BUF_SIZE = 10
const BIG_BUF_SIZE = 128

suite "Buffered socket operations":
  setup:
    discard

  test "Simple async socket single buffered test":
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

    proc testConnection() {.async.} =
      let f = server()
      var sock = newAsyncBufferedSocket(inBufSize = BUF_SIZE)
      await sock.connect("localhost", Port(16161))
      await sock.sendLine("CHECK the Socket")
      let replStr = await sock.recvLine()
      check(replStr == "CHECK complete even if the string is larger than the buffer")
      await sock.close()
      await f
    waitFor(testConnection())

  test "Simple async socket double buffered test":
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

    proc testConnection() {.async.} =
      let f = server()
      var sock = newAsyncBufferedSocket(inBufSize = BUF_SIZE, outBufSize = BUF_SIZE)
      await sock.connect("localhost", Port(16161))
      await sock.sendLine("CHECK the Socket")
      await sock.flush()
      let replStr = await sock.recvLine()
      check(replStr == "CHECK complete even if the string is larger than the buffer")
      await sock.close()
      await f
    waitFor(testConnection())

  test "Async socket double buffered reads/writes test":
    const B8_CHECK = 127'u8
    const L16_CHECK = 0xAA77'u16
    const B16_CHECK = 0x77AA'u16
    const L32_CHECK = 0x55335533'u32
    const B32_CHECK = 0x33553355'u32
    const L64_CHECK = 0xFF00FF00FF00FF00'u64
    const B64_CHECK = 0x00FF00FF00FF00FF'u64
    const F32_CHECK = 58682.7578125'f32
    const F64_CHECK = 58682.7578125'f64
    const STR_CHECK = "TEST STRING"
    const STR_LEN = STR_CHECK.len

    proc server() {.async.} =
      var sock = newAsyncBufferedSocket(inBufSize = BUF_SIZE)
      sock.setSockOpt(OptReuseAddr, true)
      sock.bindAddr(Port(16161))
      sock.listen()
      let client = await sock.accept()
      let b8 = await client.readU8()
      check(b8 == B8_CHECK)
      let l16 = await client.readU16()
      let b16 = await client.readBEU16()
      check(l16 == L16_CHECK)
      check(b16 == B16_CHECK)
      let l32 = await client.readU32()
      let b32 = await client.readBEU32()
      check(l32 == L32_CHECK)
      check(b32 == B32_CHECK)
      let l64 = await client.readU64()
      let b64 = await client.readBEU64()
      check(l64 == L64_CHECK)
      check(b64 == B64_CHECK)
      let f32 = await client.readFloat32()
      check(f32 == F32_CHECK)
      let f64 = await client.readFloat64()
      check(f64 == F64_CHECK)
      let str = await client.readString(STR_LEN)
      check(str == STR_CHECK)
      await client.close()
      await sock.close()

    proc testConnection() {.async.} =
      let f = server()
      var sock = newAsyncBufferedSocket(inBufSize = BUF_SIZE, outBufSize = BIG_BUF_SIZE)
      await sock.connect("localhost", Port(16161))
      await sock.write(B8_CHECK)
      await sock.write(L16_CHECK)
      await sock.writeBE(B16_CHECK)
      await sock.write(L32_CHECK)
      await sock.writeBE(B32_CHECK)
      await sock.write(L64_CHECK)
      await sock.writeBE(B64_CHECK)
      await sock.write(F32_CHECK)
      await sock.write(F64_CHECK)
      await sock.writeString(STR_CHECK)
      await sock.flush()
      await sock.close()
      await f
    waitFor(testConnection())
