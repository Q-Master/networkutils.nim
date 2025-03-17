import std/[os, asyncdispatch, asyncnet, net, nativesockets, endians]
import ptr_math
import ./asyncnetwork 

const DEFAULT_BUFFER_SIZE = 4096

type
  Buffer* = ref BufferObj
  BufferObj = object
    data: seq[byte]
    pos: ptr byte
    zPtr: ptr byte
    dataSize: int
    freeSpace: int

  BufferedSocketBaseObj {.inheritable.} = object
    inBuffer: Buffer
    outBuffer: Buffer
    timeout: int

  AsyncBufferedSocket* = ref AsyncBufferedSocketObj
  AsyncBufferedSocketObj* = object of BufferedSocketBaseObj
    sock: AsyncSocket
    fut: Future[int]
  
  BufferedSocket* = ref BufferedSocketObj
  BufferedSocketObj* = object of BufferedSocketBaseObj
    sock: Socket

  BufferIsTooSmallException* = object of CatchableError
  ConnectionClosedError* = object of CatchableError

proc len(s: Buffer): int {.inline.} = s.data.len()

proc resetPos(buf: Buffer) =
  buf.pos = buf.zPtr
  buf.dataSize = 0
  buf.freeSpace = buf.len()

proc advancePos(buf: Buffer, step: Natural) =
  if buf.pos + step >= buf.pos + buf.len() - 1:
    buf.resetPos()
  else:
    buf.pos += step

proc showBuffer*(sock: AsyncBufferedSocket | BufferedSocket) =
  ## Dump data contained in socket buffers
  ## 
  ## `sock` - the `AsyncBufferedSocket` or `BufferedSocket` object
  
  echo "In:"
  echo sock.inBuffer.data
  if not sock.outBuffer.isNil:
    echo "Out:"
    echo sock.outBuffer.data

proc fetchMaxAvailable(sock: AsyncBufferedSocket | BufferedSocket) {.multisync.} =
  if sock.inBuffer.freeSpace == 0 and sock.inBuffer.dataSize == 0:
    sock.inBuffer.resetPos()
  if sock.inBuffer.freeSpace > 0:
    var dataSize: int = 0
    when sock is AsyncBufferedSocket:
      dataSize = await sock.sock.recvInto(sock.inBuffer.pos+sock.inBuffer.dataSize, sock.inBuffer.freeSpace, sock.timeout)
    else:
      dataSize = sock.sock.recv(sock.inBuffer.pos+sock.inBuffer.dataSize, sock.inBuffer.freeSpace, sock.timeout)
    if dataSize == 0:
      raise newException(ConnectionClosedError, "Connection is closed")
    sock.inBuffer.dataSize += dataSize
    sock.inBuffer.freeSpace -= dataSize

proc flush(sock: AsyncSocket | Socket, data: ptr byte, size: int) {.multisync.} =
  when sock is AsyncSocket:
    await sock.send(data, size)
  else:
    var left = size
    var sent = 0
    while left > 0:
      let currentSent = sock.send(data+sent, left)
      if currentSent < 0:
        let lastError = osLastError()
        if lastError.int32 != EINTR and lastError.int32 != EWOULDBLOCK and lastError.int32 != EAGAIN:
          raise newOSError(lastError)
      else:
        sent.inc(currentSent)
        left.dec(currentSent)

proc pushMaxAvailable(sock: AsyncBufferedSocket | BufferedSocket) {.multisync.} =
  if sock.outBuffer.dataSize > 0:
    await sock.sock.flush(sock.outBuffer.zPtr, sock.outBuffer.dataSize)
    sock.outBuffer.resetPos()

proc newBuffer*(size: Natural): Buffer =
  ## Create new buffer object
  ## The buffer will be created uninitialized, might contain garbage
  ## 
  ## `size` - required size of the buffer in bytes
  
  if size > 0:
    result.new
    result.data = newSeqUninit[byte](size)
    result.zPtr = result.data[0].addr
    result.resetPos()
  else:
    result = nil

proc initSocket(sock: AsyncBufferedSocket | BufferedSocket, inBufSize: Natural, outBufSize: Natural, timeout: int) =
  sock.timeout = timeout
  sock.inBuffer = newBuffer(inBufSize)
  sock.outBuffer = newBuffer(outBufSize)

proc newBufferedSocket*(socket: Socket = nil, inBufSize = DEFAULT_BUFFER_SIZE, outBufSize = 0, timeout = -1): BufferedSocket =
  ## Create buffered socket
  ## If `socket` is not given, it will be created.
  ## 
  ## `socket` - the `Socket` object (default nil).
  ## `inBufSize` - the size of incoming buffer in bytes (default 4k, 0 - disabled)
  ## `outBufSize` - the size of outgoing buffer in bytes (default 0, 0 - disabled)
  ## `timeout` - timeout for reading data in milliseconds (default -1, -1 - disabled)
  
  result.new
  if socket.isNil:
    result.sock = newSocket(buffered = false)
  else:
    result.sock = socket
  result.initSocket(inBufSize, outBufSize, timeout)

proc newAsyncBufferedSocket*(socket: AsyncSocket = nil, inBufSize = DEFAULT_BUFFER_SIZE, outBufSize = 0, timeout = -1): AsyncBufferedSocket =
  ## Create asyncronous buffered socket
  ## If `socket` is not given, it will be created.
  ## 
  ## `socket` - the `AsyncSocket` object (default nil).
  ## `inBufSize` - the size of incoming buffer in bytes (default 4k, 0 - disabled)
  ## `outBufSize` - the size of outgoing buffer in bytes (default 0, 0 - disabled)
  ## `timeout` - timeout for reading data in milliseconds (default -1, -1 - disabled)
  
  result.new
  if socket.isNil:
    result.sock = newAsyncSocket(buffered = false)
  else:
    result.sock = socket
  result.fut = nil
  result.initSocket(inBufSize, outBufSize, timeout)

proc resizeInBuffer*(sock: AsyncBufferedSocket | BufferedSocket, newSize: Natural) =
  ## Resize incoming buffer for socket
  ## Not stable yet
  ## 
  ## `newSize` - the new size for buffer in bytes
  
  #TODO Add syncronization to block using the buffer while updating
  if newSize < sock.inBuffer.dataSize:
    raise newException(BufferIsTooSmallException, "New buffer size is too small to copy all existing data")
  let newBuf = newBuffer(newSize)
  copyMem(newBuf.zPtr, sock.inBuffer.pos, sock.inBuffer.dataSize)
  newBuf.dataSize = sock.inBuffer.dataSize
  newBuf.freeSpace = newSize - sock.inBuffer.dataSize
  sock.inBuffer = newBuffer

proc resizeOutBuffer*(sock: AsyncBufferedSocket | BufferedSocket, newSize: Natural) {.multisync.} =
  ## Resize outgoing buffer for socket
  ## Not stable yet
  ## 
  ## `newSize` - the new size for buffer in bytes
  
  #TODO Add syncronization to block using the buffer while updating
  if not sock.outBuffer.isNil and sock.outBuffer.dataSize > 0:
    await sock.pushMaxAvailable()
  let newBuf = newBuffer(newSize)
  sock.outBuffer = newBuf

proc setTimeout*(sock: AsyncBufferedSocket | BufferedSocket, timeout: int) =
  ## Set timeout value for socket
  ## 
  ## `timeout` - new timeout value in milliseconds
  
  sock.timeout = timeout

proc connect*(sock: BufferedSocket, host: string, port: Port) =
  ## Make connection to `host`:`port`
  ## 
  ## `host` - the host name or IP address
  ## `port` - the `Port` object
  
  sock.sock.connect(host, port, sock.timeout)

proc connect*(sock: BufferedSocket, host: string, port: SomeInteger | SomeUnsignedInt) =
  ## Make connection to `host`:`port`
  ## 
  ## `host` - the host name or IP address
  ## `port` - the port
  
  sock.connect(host, Port(port))

proc connect*(sock: AsyncBufferedSocket, address: string, port: Port) {.async.} =
  ## Make asyncronous connection to `host`:`port`
  ## 
  ## `host` - the host name or IP address
  ## `port` - the `Port` object

  let connFut = sock.sock.connect(address, port)
  var success = false
  if sock.timeout > 0:
    success = await connFut.withTimeout(sock.timeout)
  else:
    await connFut
    success = true
  if not success:
    raise newException(TimeoutError, "Call to 'connect' timed out.")

proc connect*(sock: AsyncBufferedSocket, address: string, port: SomeInteger | SomeUnsignedInt): Future[void] =
  ## Make asyncronous connection to `host`:`port`
  ## 
  ## `host` - the host name or IP address
  ## `port` - the port

  sock.connect(address, Port(port))

proc close*(sock: AsyncBufferedSocket | BufferedSocket) {.multisync.} =
  ## Close connection
  ## **Note** all the data in outgoing buffer will be tried to send prior to closing
  
  if not sock.outBuffer.isNil:
    await sock.pushMaxAvailable()
  sock.sock.close()

proc recvInto*(sock: AsyncBufferedSocket | BufferedSocket, dst: ptr byte, size: int) {.multisync.} =
  ## Recv data to raw buffer.
  ## If incoming buffer has less than `size` bytes of data it will try to read missing bytes from socket.
  ## 
  ## `dst` - pointer to raw buffer
  ## `size` - size of the buffer in bytes
  
  var partSize = 0
  while partSize < size:
    if sock.inBuffer.dataSize == 0:
      await sock.fetchMaxAvailable()
    let diffSize = size - partSize
    if sock.inBuffer.dataSize >= diffSize:
      copyMem(dst+partSize, sock.inBuffer.pos, diffSize)
      partSize += diffSize
      sock.inBuffer.advancePos(diffSize)
      sock.inBuffer.dataSize.dec(diffSize)
    else:
      copyMem(dst+partSize, sock.inBuffer.pos, sock.inBuffer.dataSize)
      partSize += sock.inBuffer.dataSize
      sock.inBuffer.resetPos()

proc recvInto*(sock: AsyncBufferedSocket | BufferedSocket, dst: openArray[byte]) {.multisync.} =
  ## Recv data to `openArray[byte]`.
  ## If incoming buffer has less than `size` bytes of data it will try to read missing bytes from socket.
  ## 
  ## `dst` - the openArray to read data to
  
  await sock.recvInto(cast[ptr byte](unsafeAddr(dst[0])), dst.len)

proc recv*(sock: AsyncBufferedSocket | BufferedSocket, size: int): Future[string] {.multisync.} =
  ## Recv data and return a string
  ## If incoming buffer has less than `size` bytes of data it will try to read missing bytes from socket.
  ## 
  ## `size` - length of a string in bytes
  
  result = newStringUninit(size)
  await sock.recvInto(cast[ptr byte](result[0].addr), size)
  
proc recvLine*(sock: AsyncBufferedSocket | BufferedSocket, maxLen = DEFAULT_BUFFER_SIZE): Future[string] {.multisync.} =
  ## Recv data from socket line by line
  ## If incoming buffer has less than `size` bytes of data it will try to read missing bytes from socket.
  ## 
  ## `maxLen` - the maximum possible string length

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
    result = newStringUninit(fullLen)
    copyMem(cast[ptr byte](unsafeAddr(result[0+fullLen-len])), sock.inBuffer.pos, len)
    sock.inBuffer.advancePos(len)
    #sock.inBuffer.dataSize.dec(len)
    len = 0
    if lastR:
      sock.inBuffer.advancePos(1)
      #sock.inBuffer.dataSize.dec()
    if lastL:
      sock.inBuffer.advancePos(1)
      #sock.inBuffer.dataSize.dec()
    if lastR:
      break
  if fullLen == 0:
    result = ""

proc toBuffer*(sock: AsyncBufferedSocket | BufferedSocket, size: int): Future[Buffer] {.multisync.} =
  ## Copy the `size` bytes from socket buffer to newer created `Buffer`
  ## If incoming buffer has less than `size` bytes of data it will try to read missing bytes from socket.
  ## 
  ## `size` - size of needed data in bytes
  
  result = newBuffer(size)
  await sock.recvInto(result.pos, result.len)
  result.dataSize = size
  result.freeSpace = 0

proc readInto*(inBuffer: Buffer, dst: ptr byte, size: int) =
  ## Read data from buffer to raw buffer
  ## Might throw a `BufferIsTooSmallException` exception if `size` is bigger than length of data in buffer.
  ## 
  ## `dst` - pointer to raw buffer
  ## `size` - size of needed data in bytes
  
  if inBuffer.dataSize < size:
    raise newException(BufferIsTooSmallException, "Not enough data for " & $size)
  copyMem(dst, inBuffer.pos, size)
  inBuffer.advancePos(size.Natural)
  inBuffer.dataSize.dec(size) 

proc read*(inBuffer: Buffer, size: int): string =
  ## Read data from buffer to string
  ## Might throw a `BufferIsTooSmallException` exception if `size` is bigger than length of data in buffer.
  ## 
  ## `size` - size of needed data in bytes
  
  if inBuffer.dataSize < size:
    raise newException(BufferIsTooSmallException, "Not enough data for " & $size)
  result = newStringUninit(size)
  inBuffer.readInto(cast[ptr byte](result[0].addr), size)

proc send*(sock: AsyncBufferedSocket | BufferedSocket, source: ptr byte, size: int): Future[int] {.multisync.} =
  ## Send `size` bytes from raw buffer
  ## Everything that doesn't fit in socket buffer will be immediately sent
  ## the least will be placed to socket buffer.
  ## 
  ## `source` - source raw buffer address
  ## `size` - the size of data in bytes
  
  if not sock.outBuffer.isNil:
    var ending: int = size
    var src: ptr byte = source
    if ending > sock.outBuffer.freeSpace:
      await sock.pushMaxAvailable()
    while ending > 0:
      if ending > sock.outBuffer.len:
        await sock.sock.flush(src, sock.outBuffer.len)
        src += sock.outBuffer.len
        ending.dec(sock.outBuffer.len)
      else:
        copyMem(sock.outBuffer.pos, src, ending)
        sock.outBuffer.pos += ending
        sock.outBuffer.freeSpace.dec(ending)
        sock.outBuffer.dataSize.inc(ending)
        break
  else:
    await sock.sock.flush(source, size)

proc send*(sock: BufferedSocket | AsyncBufferedSocket, data: openArray[byte]): Future[int] {.multisync.} =
  ## Send bytes from openArray
  ## Everything that doesn't fit in socket buffer will be immediately sent
  ## the least will be placed to socket buffer.
  ## 
  ## `data` - source openArray to send
  
  result = await sock.send(cast[ptr byte](unsafeAddr(data[0])), data.len)

proc send*(sock: AsyncBufferedSocket | BufferedSocket, data: string): Future[int] {.multisync.} =
  ## Send bytes from string
  ## Everything that doesn't fit in socket buffer will be immediately sent
  ## the least will be placed to socket buffer.
  ## 
  ## `data` - source string to send
  
  result = await sock.send(cast[ptr byte](unsafeAddr(data[0])), data.len)

proc fromBuffer*(sock: AsyncBufferedSocket | BufferedSocket, buffer: Buffer): Future[int] {.multisync.} =
  ## Send data from `Buffer` buffer
  ## Everything that doesn't fit in socket buffer will be immediately sent
  ## the least will be placed to socket buffer.
  ## 
  ## `buffer` - source Buffer to send
  
  await sock.send(buffer.zPtr, buffer.dataSize)

proc flush*(sock: AsyncBufferedSocket | BufferedSocket): Future[void] {.multisync.} =
  ## Flush all the data left in outgoing buffer.
  
  if not sock.outBuffer.isNil:
    await sock.pushMaxAvailable()

proc sendLine*(sock: AsyncBufferedSocket | BufferedSocket, data: string) {.multisync.} =
  ## Send one line
  ## The `data` will be appended with CRLF
  ## 
  ## `data` - the string to send
  
  var line = data & "\r\L"
  let size {.used.} = await sock.send(line)

proc setSockOpt*(sock: AsyncBufferedSocket | BufferedSocket, opt: SOBool, value: bool, level = SOL_SOCKET) {.tags: [WriteIOEffect].} =
  ## Set socket options
  sock.sock.setSockOpt(opt, value, level)

proc bindAddr*(sock: AsyncBufferedSocket | BufferedSocket, port = Port(0), address = "") {.tags: [ReadIOEffect].} =
  ## Bind socket to `address`:`port`
  ## 
  ## `port` - Port to bind to (default 0)\
  ## `address` - address to bind to (default "")

  sock.sock.bindAddr(port, address)

proc listen*(sock: AsyncBufferedSocket | BufferedSocket, backlog = SOMAXCONN) {.tags: [ReadIOEffect].} =
  ## Listen the socket
  ## 
  ## `backlog` - the depth of backlog (default SOMAXCONN)
  sock.sock.listen((backlog))

proc accept*(sock: AsyncBufferedSocket, flags = {SocketFlag.SafeDisconn}, inheritable = defined(nimInheritHandles)): Future[AsyncBufferedSocket] {.async.} =
  ## Asyncronously accept the incoming connection
  ## Will return a new created socket with accepted incoming connection
  let client = await accept(sock.sock, flags)
  result = newAsyncBufferedSocket(client, sock.inBuffer.len)

proc accept*(sock: BufferedSocket, flags = {SocketFlag.SafeDisconn}, inheritable = defined(nimInheritHandles)): BufferedSocket =
  ## Accept the incoming connection
  ## Will return a new created socket with accepted incoming connection
  result = newBufferedSocket(inBufSize = sock.inBuffer.len, outBufSize = sock.outBuffer.len)
  accept(sock.sock, result.sock, flags, inheritable)

# ----------

const sizeInt8Uint8* = sizeof(int8)
const sizeInt16Uint16* = sizeof(int16)
const sizeInt32Uint32* = sizeof(int32)
const sizeInt64Uint64* = sizeof(int64)
const sizeFloat32* = sizeof(float32)
const sizeFloat64* = sizeof(float64)

template getN(s: BufferedSocket | AsyncBufferedSocket, t: type) =
  if s.inBuffer.dataSize < sizeof(t) and s.inBuffer.freeSpace == 0:
    await s.recvInto(cast[ptr byte](result.addr), sizeof(t))
  else:
    if s.inBuffer.dataSize < sizeof(t):
        await s.fetchMaxAvailable()
    result = cast[ptr t](s.inBuffer.pos)[]
    advancePos(s.inBuffer, sizeof(t))
    s.inBuffer.dataSize.dec(sizeof(t))

template getN(inBuffer: Buffer, t: type) =
  if inBuffer.dataSize < sizeof(t):
    raise newException(BufferIsTooSmallException, "Not enough data for " & $sizeof(t))
  result = cast[ptr t](inBuffer.pos)[]
  advancePos(inBuffer, sizeof(t))
  inBuffer.dataSize.dec(sizeof(t))

proc read8*(s: BufferedSocket | AsyncBufferedSocket): Future[int8] {.multisync.} =
  s.getN(int8)

proc read8*(s: Buffer): int8 =
  s.getN(int8)

proc readU8*(s: BufferedSocket | AsyncBufferedSocket): Future[uint8] {.multisync.} =
  s.getN(uint8)

proc readU8*(s: Buffer): uint8 =
  s.getN(uint8)

proc read16*(s: BufferedSocket | AsyncBufferedSocket): Future[int16] {.multisync.} =
  s.getN(int16)

proc read16*(s: Buffer): int16 =
  s.getN(int16)

proc readBE16*(s: BufferedSocket | AsyncBufferedSocket): Future[int16] {.multisync.} =
  s.getN(int16)
  bigEndian16(addr result, addr result)

proc readBE16*(s: Buffer): int16 =
  s.getN(int16)
  bigEndian16(addr result, addr result)

proc readU16*(s: BufferedSocket | AsyncBufferedSocket): Future[uint16] {.multisync.} =
  s.getN(uint16)

proc readU16*(s: Buffer): uint16 =
  s.getN(uint16)

proc readBEU16*(s: BufferedSocket | AsyncBufferedSocket): Future[uint16] {.multisync.} =
  s.getN(uint16)
  bigEndian16(addr result, addr result)

proc readBEU16*(s: Buffer): uint16 =
  s.getN(uint16)
  bigEndian16(addr result, addr result)

proc read32*(s: BufferedSocket | AsyncBufferedSocket): Future[int32] {.multisync.} =
  s.getN(int32)

proc read32*(s: Buffer): int32 =
  s.getN(int32)

proc readBE32*(s: BufferedSocket | AsyncBufferedSocket): Future[int32] {.multisync.} =
  s.getN(int32)
  bigEndian32(addr result, addr result)

proc readBE32*(s: Buffer): int32 =
  s.getN(int32)
  bigEndian32(addr result, addr result)

proc readU32*(s: BufferedSocket | AsyncBufferedSocket): Future[uint32] {.multisync.} =
  s.getN(uint32)

proc readU32*(s: Buffer): uint32 =
  s.getN(uint32)

proc readBEU32*(s: BufferedSocket | AsyncBufferedSocket): Future[uint32] {.multisync.} =
  s.getN(uint32)
  bigEndian32(addr result, addr result)

proc readBEU32*(s: Buffer): uint32 =
  s.getN(uint32)
  bigEndian32(addr result, addr result)

proc read64*(s: BufferedSocket | AsyncBufferedSocket): Future[int64] {.multisync.} =
  s.getN(int64)

proc read64*(s: Buffer): int64 =
  s.getN(int64)

proc readBE64*(s: BufferedSocket | AsyncBufferedSocket): Future[int64] {.multisync.} =
  s.getN(int64)
  bigEndian64(addr result, addr result)

proc readBE64*(s: Buffer): int64 =
  s.getN(int64)
  bigEndian64(addr result, addr result)

proc readU64*(s: BufferedSocket | AsyncBufferedSocket): Future[uint64] {.multisync.} =
  s.getN(uint64)

proc readU64*(s: Buffer): uint64 =
  s.getN(uint64)

proc readBEU64*(s: BufferedSocket | AsyncBufferedSocket): Future[uint64] {.multisync.} =
  s.getN(uint64)
  bigEndian64(addr result, addr result)

proc readBEU64*(s: Buffer): uint64 =
  s.getN(uint64)
  bigEndian64(addr result, addr result)

proc readFloat32*(s: BufferedSocket | AsyncBufferedSocket): Future[float32] {.multisync.} =
  s.getN(float32)

proc readFloat32*(s: Buffer): float32 =
  s.getN(float32)

proc readFloat64*(s: BufferedSocket | AsyncBufferedSocket): Future[float64] {.multisync.} =
  s.getN(float64)

proc readFloat64*(s: Buffer): float64 =
  s.getN(float64)

proc readString*(s: BufferedSocket | AsyncBufferedSocket, size: int): Future[string] {.multisync.} =
  result = await s.recv(size)

proc readString*(inBuffer: Buffer, size: int): string =
  result = inBuffer.read(size)

# ----------

proc putN[T](s: BufferedSocket | AsyncBufferedSocket, some: T) {.multisync.}=
  if s.outBuffer.isNil:
    let tmp = some
    await s.sock.flush(cast[ptr byte](tmp.unsafeAddr), sizeof(T))
  else:
    if s.outBuffer.freeSpace < sizeof(T):
      await s.pushMaxAvailable()
    let tmpPtr = cast[ptr T](s.outBuffer.pos)
    tmpPtr[] = some
    advancePos(s.outBuffer, sizeof(T))
    s.outBuffer.freeSpace.dec(sizeof(T))
    s.outBuffer.dataSize.inc(sizeof(T))

template putN[T](outBuffer: Buffer, some: T) =
  if outBuffer.freeSpace < sizeof(T):
    raise newException(BufferIsTooSmallException, "Not enough data for " & $sizeof(t))
  let tmpPtr = cast[ptr T](outBuffer.pos)
  tmpPtr[] = some
  advancePos(outBuffer, sizeof(T))
  outBuffer.freeSpace.dec(sizeof(T))
  outBuffer.dataSize.inc(sizeof(T))

proc write*[T: int8 | uint8](s: BufferedSocket | AsyncBufferedSocket | Buffer, x: T) {.multisync.} =
  await putN[T](s, x)

proc write*[T: int16 | uint16](s: BufferedSocket | AsyncBufferedSocket | Buffer, x: T) {.multisync.} =
  await putN[T](s, x)

proc writeBE*[T: int16 | uint16](s: BufferedSocket | AsyncBufferedSocket | Buffer, x: T) {.multisync.} =
  var n = x
  bigEndian16(addr n, addr n)
  await putN[T](s, n)

proc write*[T: int32 | uint32](s: BufferedSocket | AsyncBufferedSocket | Buffer, x: T) {.multisync.} =
  await putN[T](s, x)

proc writeBE*[T: int32 | uint32](s: BufferedSocket | AsyncBufferedSocket | Buffer, x: T) {.multisync.} =
  var n = x
  bigEndian32(addr n, addr n)
  await putN[T](s, n)

proc write*[T: int64 | uint64](s: BufferedSocket | AsyncBufferedSocket | Buffer, x: T) {.multisync.} =
  await putN[T](s, x)

proc writeBE*[T: int64 | uint64](s: BufferedSocket | AsyncBufferedSocket | Buffer, x: T) {.multisync.} =
  var n = x
  bigEndian64(addr n, addr n)
  await putN[T](s, n)

proc write*[T: float32 | float64](s: BufferedSocket | AsyncBufferedSocket | Buffer, x: T) {.multisync.} =
  await putN[T](s, x)

proc writeString*(s: BufferedSocket | AsyncBufferedSocket, str: string) {.multisync.} =
  let x {.used.} = await s.send(str)

#-- some debug code

proc setInBuffer*(s: BufferedSocket | AsyncBufferedSocket, data: sink string | seq[byte]) =
  var size = data.len
  if size > s.inBuffer.data.len:
    size = s.inBuffer.data.len
  copyMem(s.inBuffer.data[0].addr, data[0].unsafeAddr, size)
  s.inBuffer.dataSize = size
  s.inBuffer.freeSpace = s.inBuffer.data.len - size
  s.inBuffer.pos = s.inBuffer.zPtr
