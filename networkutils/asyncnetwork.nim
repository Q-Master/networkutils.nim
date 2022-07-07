
import std/[asyncdispatch, asyncnet, net]

proc recvInto*(socket: AsyncSocket, buf: pointer, size: int, timeout: int, flags = {SocketFlag.SafeDisconn}): owned(Future[int]) =
  ## Version of asyncdispatch.`recvInto` with timeout.
  ##
  ## Reads **up to** `size` bytes from `socket` into `buf`.
  ##
  ## For buffered sockets this function will attempt to read all the requested
  ## data. It will read this data in `BufferSize` chunks.
  ##
  ## For unbuffered sockets this function makes no effort to read
  ## all the data requested. It will return as much data as the operating system
  ## gives it.
  ##
  ## If socket is disconnected during the
  ## recv operation then the future may complete with only a part of the
  ## requested data.
  ##
  ## If socket is disconnected and no data is available
  ## to be read then the future will complete with a value of `0`.
  ##
  ## A timeout may be specified in milliseconds, if enough data is not received
  ## within the time specified a TimeoutError exception will be raised.
  ##
  ## .. warning:: Only the `SafeDisconn` flag is currently supported.
  var retFuture: Future[int]
  if timeout == -1:
    retFuture = socket.recvInto(buf, size, flags)
  else:
    retFuture = newFuture[int]("networkutils.asyncnetwork.`recvInto`")
    var readingFuture = newFuture[void]("networkutils.asyncnetwork.`recvInto`.reading")
    var timeoutFuture = sleepAsync(timeout)
    addRead(socket.getFd.AsyncFD, proc(fd: AsyncFD): bool =
      result = true
      readingFuture.complete()
    )
    readingFuture.callback =
      proc() =
        if not timeoutFuture.finished:
          var fut = socket.recvInto(buf, size, flags)
          fut.callback =
            proc() =
              if fut.failed:
                if not retFuture.finished: retFuture.fail(fut.error)
              else:
                if not retFuture.finished: retFuture.complete(fut.read)
    timeoutFuture.callback =
      proc() =
        if not retFuture.finished and not readingFuture.finished: retFuture.fail(newException(TimeoutError, "Call to read timed out."))
  return retFuture