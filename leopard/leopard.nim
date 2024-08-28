## Nim-Leopard
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import pkg/upraises
push: {.upraises: [].}

{.deadCodeElim: on.}

import pkg/stew/results

import ./wrapper
import ./utils

export wrapper, results

const
  BuffMultiples* = 64

type
  LeoBufferPtr* = ptr UncheckedArray[byte]

  LeoCoderKind* {.pure.} = enum
    Encoder,
    Decoder

  Leo* = object of RootObj
    bufSize*: int                         # size of the buffer in multiples of 64
    buffers*: int                         # total number of data buffers (K)
    parity*: int                          # total number of parity buffers (M)
    dataBufferPtr: seq[LeoBufferPtr]      # buffer where data is copied before encoding
    workBufferCount: int                  # number of parity work buffers
    workBufferPtr: seq[LeoBufferPtr]      # buffer where parity data is written during encoding or before decoding

    dataBufferNil: seq[bool]             # true represents Nil in dataBufferPtr
    workBufferNil: seq[bool]             # true represents nil in workBufferPtr
    case kind: LeoCoderKind
    of LeoCoderKind.Decoder:
      decodeBufferCount: int              # number of decoding work buffers
      decodeBufferPtr: seq[LeoBufferPtr]  # work buffer used for decoding
    of LeoCoderKind.Encoder:
      discard

  LeoEncoder* = object of Leo
  LeoDecoder* = object of Leo


func prepareEncode*(
  self: var LeoEncoder,
  data: var openArray[seq[byte]]
  ): Result[void, cstring] =
  ## Copy `data` into internal encode buffer
  ##
  
  if data.len != self.buffers:
    return err("Number of data buffers should match!")

  # copy data into aligned buffer
  for i in 0..<self.buffers:
    copyMem(self.dataBufferPtr[i], addr data[i][0], self.bufSize)
  
  ok()

func encodePrepared*(
  self: var LeoEncoder
  ): Result[void, cstring] =
  ## Encode using previously prepared buffer (using `prepareEncode`)
  ##

  # zero encode work buffer to avoid corrupting with previous run
  for i in 0..<self.workBufferCount:
    zeroMem(self.workBufferPtr[i], self.bufSize)

  let
    res = leoEncode(
      self.bufSize.culonglong,
      self.buffers.cuint,
      self.parity.cuint,
      self.workBufferCount.cuint,
      cast[LeoDataPtr](addr self.dataBufferPtr[0]),
      cast[ptr pointer](addr self.workBufferPtr[0]))

  if ord(res) != ord(LeopardSuccess):
    return err(leoResultString(res.LeopardResult))

  ok()

func readParity*(
  self: var LeoEncoder,
  parity: var openArray[seq[byte]]
): Result[void, cstring] =
  ## Copies previously encoded parity data into `parity` buffer
  ##

  if parity.len != self.parity:
    return err("Number of parity buffers should match!")

  for i in 0..<parity.len:
    copyMem(addr parity[i][0], self.workBufferPtr[i], self.bufSize)

  ok()

func encode*(
  self: var LeoEncoder,
  data,
  parity: var openArray[seq[byte]]): Result[void, cstring] =
  ## Encode a list of buffers in `data` into a number of `bufSize` sized
  ## `parity` buffers
  ##
  ## `data`   - list of original data `buffers` of size `bufSize`
  ## `parity` - list of parity `buffers` of size `bufSize`
  ##

  let res = self.prepareEncode(data)

  if res.isErr():
    return res

  let res2 = self.encodePrepared()

  if res2.isErr():
    return res2

  self.readParity(parity)

func prepareDecode*(
  self: var LeoDecoder,
  data,
  parity: var openArray[seq[byte]]
  ): Result[void, cstring] =

  if data.len != self.buffers:
    return err("Number of data buffers should match!")

  if parity.len != self.parity:
    return err("Number of parity buffers should match!")

  # clean out work and data buffers
  for i in 0..<self.buffers:
    zeroMem(self.dataBufferPtr[i], self.bufSize)

  for i in 0..<self.workBufferCount:
    zeroMem(self.workBufferPtr[i], self.bufSize)

  # copy data into aligned buffer
  for i in 0..<data.len:
    if data[i].len > 0:
      copyMem(self.dataBufferPtr[i], addr data[i][0], self.bufSize)
      self.dataBufferNil[i] = false
    else:
      self.dataBufferNil[i] = true

  # copy parity into aligned buffer
  for i in 0..<self.workBufferCount:
    if i < parity.len and parity[i].len > 0:
      copyMem(self.workBufferPtr[i], addr parity[i][0], self.bufSize)
      self.workBufferNil[i] = false
    else:
      self.workBufferNil[i] = true

  ok()

func decodePrepared*(
  self: var LeoDecoder
  ): Result[void, cstring] =

  for i in 0..<self.decodeBufferCount:
    zeroMem(self.decodeBufferPtr[i], self.bufSize)

  # this is needed because erasures are nil pointers
  var
    dataPtr = newSeq[LeoBufferPtr](self.buffers)
    parityPtr = newSeq[LeoBufferPtr](self.workBufferCount)

  # copy data into aligned buffer
  for i in 0..<self.buffers:
    if self.dataBufferNil[i]:
      dataPtr[i] = nil 
    else:
      dataPtr[i] = self.dataBufferPtr[i]

  # copy parity into aligned buffer
  for i in 0..<self.workBufferCount:
    if self.workBufferNil[i]:
      parityPtr[i] = nil
    else:
      parityPtr[i] = self.workBufferPtr[i]
      
  let
    res = leoDecode(
      self.bufSize.culonglong,
      self.buffers.cuint,
      self.parity.cuint,
      self.decodeBufferCount.cuint,
      cast[LeoDataPtr](addr dataPtr[0]),
      cast[LeoDataPtr](addr parityPtr[0]),
      cast[ptr pointer](addr self.decodeBufferPtr[0]))

  if ord(res) != ord(LeopardSuccess):
    return err(leoResultString(res.LeopardResult))

  ok()

func readDecoded*(
  self: var LeoDecoder,
  recovered: var openArray[seq[byte]]
): Result[void, cstring] =

  if recovered.len != self.buffers:
    return err("Number of recovered buffers should match buffers!")

  for i, wasNil in self.dataBufferNil:
    if wasNil:
      copyMem(addr recovered[i][0], self.decodeBufferPtr[i], self.bufSize)
  
  ok()


func decode*(
  self: var LeoDecoder,
  data,
  parity,
  recovered: var openArray[seq[byte]]): Result[void, cstring] =
  ## Decode a list of buffers in `data` and `parity` into a list
  ## of `recovered` buffers of `bufSize`. The list of `recovered`
  ## buffers should be match the `Leo.buffers`
  ##
  ## `data`       - list of original data `buffers` of size `bufSize`
  ## `parity`     - list of parity `buffers` of size `bufSize`
  ## `recovered`  - list of recovered `buffers` of size `bufSize`
  ##

  let res = self.prepareDecode(data, parity)

  if res.isErr():
    return res

  let res2 = self.decodePrepared()

  if res2.isErr():
    return res2

  self.readDecoded(recovered)

func free*(self: var Leo) =
  if self.dataBufferNil.len > 0:
    self.dataBufferNil.setLen(0)

  if self.workBufferNil.len > 0:
    self.workBufferNil.setLen(0)

  if self.workBufferPtr.len > 0:
    for i, p in self.workBufferPtr:
      if not isNil(p):
        p.leoFree()
        self.workBufferPtr[i] = nil

    self.workBufferPtr.setLen(0)

  if self.dataBufferPtr.len > 0:
    for i, p in self.dataBufferPtr:
      if not isNil(p):
        p.leoFree()
        self.dataBufferPtr[i] = nil

    self.dataBufferPtr.setLen(0)

  if self.kind == LeoCoderKind.Decoder:
    if self.decodeBufferPtr.len > 0:
      for i, p in self.decodeBufferPtr:
        if not isNil(p):
          p.leoFree()
          self.decodeBufferPtr[i] = nil
      self.decodeBufferPtr.setLen(0)

# TODO: The destructor doesn't behave as
# I'd expect it, it's called many more times
# than it should. This is however, most
# likely my misinterpretation of how it should
# work.
# proc `=destroy`*(self: var Leo) =
#   self.free()

proc init[TT: Leo](
  T: type TT,
  bufSize,
  buffers,
  parity: int,
  kind: LeoCoderKind): Result[T, cstring] =
  if bufSize mod BuffMultiples != 0:
    return err("bufSize should be multiples of 64 bytes!")

  if parity > buffers:
    return err("number of parity buffers cannot exceed number of data buffers!")

  if (buffers + parity) > 65536:
    return err("number of parity and data buffers cannot exceed 65536!")

  once:
    # First, attempt to init the leopard library,
    # this happens only once for all threads and
    # should be safe as internal tables are only read,
    # never written. However instantiation should be
    # synchronized, since two instances can attempt to
    # concurrently instantiate the library twice, and
    # might end up with two distinct versions - not a big
    # deal but will defeat the purpose of this `once` block
    if (let res = leoInit(); res.ord != LeopardSuccess.ord):
      return err(leoResultString(res.LeopardResult))

  var
    self = T(
      kind: kind,
      bufSize: bufSize,
      buffers: buffers,
      parity: parity)

  self.workBufferCount = leoEncodeWorkCount(
    buffers.cuint,
    parity.cuint).int

  self.workBufferNil.setLen(self.workBufferCount)
  self.dataBufferNil.setLen(self.buffers)

  # initialize encode work buffers
  for _ in 0..<self.workBufferCount:
    self.workBufferPtr.add(cast[LeoBufferPtr](self.bufSize.leoAlloc()))

  # initialize data buffers
  for _ in 0..<self.buffers:
    self.dataBufferPtr.add(cast[LeoBufferPtr](self.bufSize.leoAlloc()))

  if self.kind == LeoCoderKind.Decoder:
    self.decodeBufferCount = leoDecodeWorkCount(
      buffers.cuint,
      parity.cuint).int

    # initialize decode work buffers
    for _ in 0..<self.decodeBufferCount:
      self.decodeBufferPtr.add(cast[LeoBufferPtr](self.bufSize.leoAlloc()))

  ok(self)

proc init*(
  T: type LeoEncoder,
  bufSize,
  buffers,
  parity: int): Result[LeoEncoder, cstring] =
  LeoEncoder.init(bufSize, buffers, parity, LeoCoderKind.Encoder)

proc init*(
  T: type LeoDecoder,
  bufSize,
  buffers,
  parity: int): Result[LeoDecoder, cstring] =
  LeoDecoder.init(bufSize, buffers, parity, LeoCoderKind.Decoder)
