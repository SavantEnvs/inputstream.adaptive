#include "ts_demux_run.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
  RunTsDemux(data, size, nullptr);
  return 0;
}
