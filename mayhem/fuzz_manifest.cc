// Fuzz harness for the adaptive-streaming manifest parsers (DASH MPD, HLS m3u8, Smooth ISM).
// Built three times with -DFUZZ_DASH / -DFUZZ_HLS / -DFUZZ_SMOOTH. Bytes only come from the fuzzer;
// every "download" a parser asks for is answered in memory (HLS child playlists get the input back).
#include "CompKodiProps.h"
#include "SrvBroker.h"
#include "common/ChooserDefault.h"
#include "parser/DASHTree.h"
#include "parser/HLSTree.h"
#include "parser/SmoothTree.h"
#include "utils/CurlUtils.h"

#include <pugixml.hpp>

#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace
{
class FuzzChooser : public CHOOSER::CRepresentationChooserDefault
{
public:
  void Initialize(const ADP::KODI_PROPS::ChooserProps&) override {}
};

#if defined(FUZZ_DASH)
class FuzzTree : public adaptive::CDashTree
{
public:
  FuzzTree() : CDashTree() {}
  uint64_t GetTimestamp() override { return 10000000000; }
  CDashTree* Clone() const override { return new FuzzTree{*this}; }
  void Update(const std::string& data) { m_updateData = data; OnUpdateSegments(); }

protected:
  int64_t ResolveUTCTiming(pugi::xml_node) override { return 0; }
  bool DownloadManifestUpd(const std::string& url,
                           const std::map<std::string, std::string>&,
                           const std::vector<std::string>&,
                           UTILS::CURL::HTTPResponse& resp) override
  {
    resp.effectiveUrl = url;
    resp.data = m_updateData;
    return true;
  }

private:
  std::string m_updateData;
};
static const char* kUrl = "http://foo.bar/manifest.mpd";
#elif defined(FUZZ_HLS)
class FuzzTree : public adaptive::CHLSTree
{
public:
  FuzzTree() : CHLSTree() {}
  CHLSTree* Clone() const override { return new FuzzTree{*this}; }
  void SetData(const std::string& data) { m_data = data; }

protected:
  bool DownloadKey(const std::string&,
                   const std::map<std::string, std::string>&,
                   const std::vector<std::string>&,
                   UTILS::CURL::HTTPResponse&) override
  {
    return false;
  }
  bool DownloadManifestChild(const std::string& url,
                             const std::map<std::string, std::string>&,
                             const std::vector<std::string>&,
                             UTILS::CURL::HTTPResponse& resp) override
  {
    resp.effectiveUrl = url;
    resp.data = m_data;
    return true;
  }

private:
  std::string m_data;
};
static const char* kUrl = "http://foo.bar/master.m3u8";
#elif defined(FUZZ_SMOOTH)
class FuzzTree : public adaptive::CSmoothTree
{
public:
  FuzzTree() : CSmoothTree() {}
  CSmoothTree* Clone() const override { return new FuzzTree{*this}; }
};
static const char* kUrl = "http://foo.bar/stream.ism/manifest";
#else
#error "define one of FUZZ_DASH, FUZZ_HLS, FUZZ_SMOOTH"
#endif
} // namespace

extern "C" int LLVMFuzzerInitialize(int*, char***)
{
  CSrvBroker::GetInstance()->Initialize();
  CSrvBroker::GetInstance()->InitStage1({});
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
  const std::string manifest(reinterpret_cast<const char*>(data), size);

  FuzzChooser chooser;
  chooser.Initialize({});
  chooser.SetDownloadSpeed(500000);

  FuzzTree tree;
  tree.Configure(&chooser, "");

#if defined(FUZZ_HLS)
  tree.SetData(manifest);
#endif

  const bool opened = tree.Open(kUrl, {}, manifest);
  if (opened)
  {
    tree.PostOpen();
#if defined(FUZZ_HLS)
    if (!tree.m_periods.empty())
    {
      auto* period = tree.m_periods[0].get();
      auto& adpSets = period->GetAdaptationSets();
      if (!adpSets.empty() && !adpSets[0]->GetRepresentations().empty())
        tree.PrepareRepresentation(period, adpSets[0].get(), adpSets[0]->GetRepresentations()[0].get());
    }
#elif defined(FUZZ_DASH)
    tree.Update(manifest);
#endif
  }
  tree.Uninitialize();
  return opened ? 0 : -1;
}
