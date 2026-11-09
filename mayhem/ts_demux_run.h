// Drives lib/mpegts the way src/TSReader.cpp does: resync, process the packet, process the PES payload,
// start every stream the PMT announces, and pull the elementary-stream packets out.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstring>
#include "tsDemuxer.h"

namespace
{
class MemDemuxer : public TSDemux::TSDemuxer
{
public:
  MemDemuxer(const uint8_t* d, size_t n) : m_data(d), m_size(n) {}
  bool ReadAV(uint64_t pos, unsigned char* buf, size_t len) override
  {
    if (pos > m_size || len > m_size - pos)
      return false;
    memcpy(buf, m_data + pos, len);
    return true;
  }

private:
  const uint8_t* m_data;
  size_t m_size;
};

// Returns the number of elementary-stream packets produced; `dump` (may be null) gets a line per stream.
size_t RunTsDemux(const uint8_t* data, size_t size, FILE* dump)
{
  MemDemuxer demux(data, size);
  TSDemux::AVContext ctx(&demux, 0, 0);
  size_t packets = 0;

  for (;;)
  {
    if (ctx.TSResync() != TSDemux::AVCONTEXT_CONTINUE)
      break;
    int status = ctx.ProcessTSPacket();

    while (ctx.HasPIDStreamData())
    {
      TSDemux::ElementaryStream* es = ctx.GetPIDStream();
      TSDemux::STREAM_PKT pkt;
      if (!es || !es->GetStreamPacket(&pkt))
        break;
      ++packets;
    }

    if (ctx.HasPIDPayload())
    {
      status = ctx.ProcessTSPayload();
      if (status == TSDemux::AVCONTEXT_PROGRAM_CHANGE)
        for (TSDemux::ElementaryStream* es : ctx.GetStreams())
          ctx.StartStreaming(es->pid);
    }

    if (status == TSDemux::AVCONTEXT_TS_ERROR)
      ctx.Shift();
    else
      ctx.GoNext();
  }

  if (dump)
  {
    for (TSDemux::ElementaryStream* es : ctx.GetStreams())
      fprintf(dump, "pid=%u codec=%s info=%d %dx%d\n", es->pid, es->GetStreamCodecName(),
              es->has_stream_info ? 1 : 0, es->stream_info.width, es->stream_info.height);
    fprintf(dump, "packets=%zu\n", packets);
  }
  return packets;
}
} // namespace
