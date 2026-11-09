#include "ts_demux_run.h"
#include <fstream>
#include <iterator>
#include <vector>

int main(int argc, char** argv)
{
  if (argc != 2)
    return 2;
  std::ifstream f(argv[1], std::ios::binary);
  std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
  RunTsDemux(buf.data(), buf.size(), stdout);
  return 0;
}
