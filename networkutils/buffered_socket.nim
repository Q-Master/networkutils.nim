import std/[asyncdispatch, asyncnet, net, nativesockets]
import ptr_math

const DEFAULT_BUFFER_SIZE = 4096

type
  Buffer = ref BufferObj
  BufferObj = object of RootObj
    data: seq[byte]
    pos: ptr byte
    dataSize: int
    freeSpace: int

  BufferedSocketBaseObj = object of RootObj
    inBuffer: Buffer
    outBuffer: Buffer

  AsyncBufferedSocket* = ref AsyncBufferedSocketObj
  AsyncBufferedSocketObj* = object of BufferedSocketBaseObj
    sock: AsyncSocket
  
  BufferedSocket* = ref BufferedSocketObj
  BufferedSocketObj* = object of BufferedSocketBaseObj
    sock: Socket


proc resetPos(buf: Buffer) =
  buf.pos = cast[ptr byte](addr(buf.data[0]))
  buf.dataSize = 0
  buf.freeSpace = buf.data.len

proc advancePos(buf: Buffer, step: int) =
  if buf.pos + step >= buf.pos + buf.data.len - 1:
    buf.resetPos()
  else:
    if buf.dataSize >= step:
      buf.pos += step
      buf.dataSize -= step
    else:
      buf.resetPos()

proc fetchMaxAvailable(sock: AsyncBufferedSocket | BufferedSocket) {.multisync.} =
  if sock.inBuffer.freeSpace == 0 and sock.inBuffer.dataSize == 0:
    sock.inBuffer.resetPos()
  if sock.inBuffer.freeSpace > 0:
    when sock is AsyncBufferedSocket:
        var dataSize = await sock.sock.recvInto(sock.inBuffer.pos+sock.inBuffer.dataSize, sock.inBuffer.freeSpace)
    else:
      var dataSize = sock.sock.recv(sock.inBuffer.pos+sock.inBuffer.dataSize, sock.inBuffer.freeSpace)
    sock.inBuffer.dataSize += dataSize
    sock.inBuffer.freeSpace -= dataSize

proc newBuffer(size: Natural): Buffer =
  if size > 0:
    result.new
    result.data.setLen(size)
    result.resetPos()
  else:
    result = nil

proc newBufferedSocket*(socket: Socket = nil, bufSize = DEFAULT_BUFFER_SIZE): BufferedSocket =
  result.new
  if socket.isNil:
    result.sock = newSocket(buffered = false)
  else:
    result.sock = socket
  result.inBuffer = newBuffer(bufSize)

proc newAsyncBufferedSocket*(socket: AsyncSocket = nil, bufSize = DEFAULT_BUFFER_SIZE): AsyncBufferedSocket =
  result.new
  if socket.isNil:
    result.sock = newAsyncSocket(buffered = false)
  else:
    result.sock = socket
  result.inBuffer = newBuffer(bufSize)

proc connect*(sock: AsyncBufferedSocket | BufferedSocket, address: string, port: Port) {.multisync.} =
  await sock.sock.connect(address, port)

proc connect*(sock: AsyncBufferedSocket | BufferedSocket, address: string, port: SomeInteger | SomeUnsignedInt) {.multisync.} =
  await sock.sock.connect(address, Port(port))

proc close*(sock: AsyncBufferedSocket | BufferedSocket) =
  sock.sock.close()

proc recvInto*(sock: AsyncBufferedSocket | BufferedSocket, dst: ptr byte, size: int): Future[int] {.multisync.} =
  # if inBuffer has less than size dataSize we should copy all the dataSize, reset the pos
  # and dataSize and download more bufLen bytes
  var partSize = 0
  while partSize < size:
    if sock.inBuffer.dataSize == 0:
      await sock.fetchMaxAvailable()
    let diffSize = size - partSize
    if sock.inBuffer.dataSize >= diffSize:
      copyMem(dst+partSize, sock.inBuffer.pos, diffSize)
      partSize += diffSize
      sock.inBuffer.advancePos(diffSize)
    else:
      copyMem(dst+partSize, sock.inBuffer.pos, sock.inBuffer.dataSize)
      partSize += sock.inBuffer.dataSize
      sock.inBuffer.resetPos()
  result = size

proc recvInto*(sock: AsyncBufferedSocket | BufferedSocket, dst: openArray[byte]): Future[int] {.multisync.} =
  result = await sock.recvInto(cast[ptr byte](unsafeAddr(dst[0])), dst.len)

proc recv*(sock: AsyncBufferedSocket | BufferedSocket, size: int): Future[string] {.multisync.} =
  result.setLen(size)
  let newSize = await sock.recvInto(cast[ptr byte](result[0].addr), size)
  if newSize != size:
    raise newException(IOError, "Sizes don't match")

proc recvLine*(sock: AsyncBufferedSocket | BufferedSocket, maxLen = DEFAULT_BUFFER_SIZE): Future[string] {.multisync.} =
  var lastR: bool = false
  var lastL: bool = false
  var len, fullLen: int = 0
  while fullLen < maxLen:
    if sock.inBuffer.dataSize == 0:
      await sock.fetchMaxAvailable()
    for i in 0 .. sock.inBuffer.dataSize-1:
      case (sock.inBuffer.pos+i)[]
      of '\r'.byte:
        lastR = true
      of '\L'.byte:
        lastL = true
        break
      else:
        if lastR:
          break
        len.inc()
    fullLen += len
    result.setLen(fullLen)
    copyMem(cast[ptr byte](unsafeAddr(result[0+fullLen-len])), sock.inBuffer.pos, len)
    sock.inBuffer.advancePos(len)
    len = 0
    if lastR:
      sock.inBuffer.advancePos(1)
    if lastL:
      sock.inBuffer.advancePos(1)
    if lastR:
      break
  if fullLen == 0:
    result = ""

proc send*(sock: AsyncBufferedSocket | BufferedSocket, source: ptr byte, size: int): Future[int] {.multisync.} =
  when sock is AsyncBufferedSocket:
    await sock.sock.send(source, size)
  else:
    var left = size
    while left > 0:
      let sz = sock.sock.send(source, left)
      left -= sz
  result = size

proc send*(sock: AsyncBufferedSocket | BufferedSocket, data: openArray[byte]): Future[int] {.multisync.} =
  result = await sock.send(cast[ptr byte](unsafeAddr(data[0])), data.len)

proc send*(sock: AsyncBufferedSocket | BufferedSocket, data: string): Future[int] {.multisync.} =
  result = await sock.send(cast[ptr byte](unsafeAddr(data[0])), data.len)

proc sendLine*(sock: AsyncBufferedSocket | BufferedSocket, data: string) {.multisync.} =
  var line = data & "\r\L"
  let size {.used.} = await sock.send(line)

proc setSockOpt*(sock: AsyncBufferedSocket | BufferedSocket, opt: SOBool, value: bool, level = SOL_SOCKET) {.tags: [WriteIOEffect].} =
  sock.sock.setSockOpt(opt, value, level)

proc bindAddr*(sock: AsyncBufferedSocket | BufferedSocket, port = Port(0), address = "") {.tags: [ReadIOEffect].} =
  sock.sock.bindAddr(port, address)

proc listen*(sock: AsyncBufferedSocket | BufferedSocket, backlog = SOMAXCONN) {.tags: [ReadIOEffect].} =
  sock.sock.listen((backlog))

proc accept*(sock: AsyncBufferedSocket, flags = {SocketFlag.SafeDisconn}, inheritable = defined(nimInheritHandles)): Future[AsyncBufferedSocket] {.async.} =
  let client = await accept(sock.sock, flags)
  result = newAsyncBufferedSocket(client, sock.inBuffer.data.len)

proc accept*(sock: BufferedSocket, flags = {SocketFlag.SafeDisconn}, inheritable = defined(nimInheritHandles)): BufferedSocket =
  result = newBufferedSocket(bufsize = sock.inBuffer.data.len)
  accept(sock.sock, result.sock, flags, inheritable)
