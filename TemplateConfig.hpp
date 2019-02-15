#ifndef TEMPLATECONFIG_HPP
#define TEMPLATECONFIG_HPP

#include <fstream>

#include "AlgorithmConfig.hpp"
#include "GraphLoader.hpp"
#include "Timer.hpp"

enum class work_division { vertex, edge };

template<typename Platform, typename V, typename E, typename... Args>
struct WarpKernel;

template<typename Platform, typename V, typename E, typename... Args>
struct GraphKernel
{
    template<typename, typename, typename, typename...>
    friend struct TemplateConfig;

    using WarpVersion = WarpKernel<Platform,V,E,Args...>;

  protected:
    Platform &backend;

  public:
    virtual void run(GraphLoader<Platform,V,E>&, const Args&...) = 0;

    GraphKernel(GraphRep rep, work_division w)
     : backend(Platform::get())
     , representation(rep)
     , workDivision(w)
    {}

    virtual ~GraphKernel()
    {}

    virtual size_t getSharedMemSize(size_t)
    { return 0; }

    const GraphRep representation;
    const work_division workDivision;
};

template<typename Platform, typename V, typename E, typename... Args>
struct WarpKernel : GraphKernel<Platform,V,E,Args...>
{
    using GraphKernel<Platform,V,E,Args...>::backend;

    static size_t dummy;

    WarpKernel(GraphRep r, work_division w, std::function<size_t(size_t)> mem)
     : GraphKernel<Platform,V,E,Args...>(r, w)
     , warp_size(dummy), chunk_size(dummy), chunkMemory(mem)
    {}

    std::reference_wrapper<size_t> warp_size, chunk_size;

  protected:
    virtual size_t getSharedMemSize(size_t blockSize) override
    { return (blockSize / warp_size.get()) * chunkMemory(chunk_size.get()); }

    std::function<size_t(size_t)> chunkMemory;
};

template<typename Platform, typename V, typename E, typename... Args>
size_t WarpKernel<Platform,V,E,Args...>::dummy = 0;

template
< typename Platform
, typename V
, typename E
, Rep rep
, Dir dir
, typename Kernel
, typename KernelType
, typename... KernelArgs
>
struct DerivedKernel : KernelType
{
    using KernelType::backend;
    using KernelType::representation;
    using GraphKernel = GraphKernel<Platform,V,E,KernelArgs...>;
    using WarpKernel = WarpKernel<Platform,V,E,KernelArgs...>;

    Kernel kernel;

    template<typename... Args>
    DerivedKernel(Args... args)
     : KernelType({rep, dir}, args...), kernel(nullptr)
    {}

    template<typename... Args>
    DerivedKernel(Kernel kern, Args... args)
     : KernelType({rep, dir}, args...), kernel(kern)
    {}

    virtual void
    run(GraphLoader<Platform,V,E>& loader, const KernelArgs&... args) override
    { doRun(loader, args...); }

    template<class Parent = KernelType>
    typename std::enable_if<std::is_same<WarpKernel,Parent>::value,void>::type
    doRun(GraphLoader<Platform,V,E>& loader, const KernelArgs&... args)
    {
        if (kernel == nullptr) return;

        const auto& graph = loader.template getGraph<rep,dir>();
        backend.runKernel
            ( kernel, this->warp_size.get(), this->chunk_size.get()
            , graph, args...);
    }

    template<class Parent = KernelType>
    typename std::enable_if<std::is_same<GraphKernel,Parent>::value,void>::type
    doRun(GraphLoader<Platform,V,E>& loader, const KernelArgs&... args)
    {
        if (kernel == nullptr) return;

        const auto& graph = loader.template getGraph<rep,dir>();
        backend.runKernel(kernel, graph, args...);
    }
};

template<typename Platform, typename V, typename E, typename... Args>
using KernelType = std::shared_ptr<GraphKernel<Platform,V,E,Args...>>;

template<typename Platform, typename V, typename E>
class KernelBuilder
{
    template
    < Rep rep
    , Dir dir
    , typename Graph
    , typename... Args
    , typename Ptr = typename Platform::template kernel<Graph,Args...>::type
    , typename Base = GraphKernel<Platform,V,E,Args...>
    , typename Derived = DerivedKernel<Platform,V,E,rep,dir,Ptr,Base,Args...>
    >
    KernelType<Platform,V,E,Args...>
    make_kernel(Ptr k, work_division w, std::tuple<Args...>)
    { return std::make_shared<Derived>(k,w); }

  public:
    KernelBuilder() {}
    ~KernelBuilder() {}

    template
    < Rep rep
    , Dir dir = Dir::Forward
    , typename... Args
    , typename Graph = typename LoaderRep<rep,Platform,V,E>::GraphType
    , typename ArgPack = std::tuple
        < typename Platform::template DevToHost<Args>::type...>
    >
    auto
    operator()(void (*k)(Graph, Args...), work_division w)
    { return make_kernel<rep,dir,Graph>(k, w, ArgPack()); }
};

#define make_kernel(kernel, work_div, ...) \
    make_kernel.operator()<__VA_ARGS__>(kernel, work_div)

#define make_kernel_pair(name, kernel, work_div, ...) \
    std::pair{name, make_kernel.operator()<__VA_ARGS__>(kernel, work_div)}

template<typename Platform, typename V, typename E>
class WarpKernelBuilder
{
    template
    < Rep rep
    , Dir dir
    , typename Graph
    , typename... Args
    , typename Ptr =
        typename Platform::template kernel<size_t,size_t,Graph,Args...>::type
    , typename Base = WarpKernel<Platform,V,E,Args...>
    , typename Derived = DerivedKernel<Platform,V,E,rep,dir,Ptr,Base,Args...>
    , typename SizeFun = std::function<size_t(size_t)>
    >
    KernelType<Platform,V,E,Args...>
    make_warp_kernel
    (Ptr k, work_division w, SizeFun mem, std::tuple<Args...>)
    { return std::make_shared<Derived>(k,w, mem); }

  public:
    WarpKernelBuilder() {}
    ~WarpKernelBuilder() {}

    template
    < Rep rep
    , Dir dir = Dir::Forward
    , typename... Args
    , typename Graph = typename LoaderRep<rep,Platform,V,E>::GraphType
    , typename ArgPack = std::tuple
        < typename Platform::template DevToHost<Args>::type...>
    , typename SizeFun = std::function<size_t(size_t)>
    >
    auto
    operator()
    (void (*k)(size_t, size_t, Graph, Args...), work_division w, SizeFun mem)
    { return make_warp_kernel<rep,dir,Graph>(k, w, mem, ArgPack()); }
};

#define make_warp_kernel(kernel, work_div, mem, ...) \
    make_warp_kernel.operator()<__VA_ARGS__>(kernel, work_div, mem)

#define make_warp_kernel_pair(name, kernel, work_div, mem, ...) \
    std::pair{name, make_warp_kernel.operator()<__VA_ARGS__>(kernel, work_div, mem) }

template<typename Key, typename T>
class KernelMap : public std::map<Key,T>
{
  public:
    KernelMap() {}

    KernelMap(std::initializer_list<std::pair<Key,T>> l)
      : std::map<Key,T>(l.begin(), l.end())
    {}

    KernelMap&
    operator+=(const KernelMap& other)
    {
        for (auto& pair : other) {
            auto result = this->insert(pair);
            if (!result.second) throw std::domain_error("Key already exists!");
        }

        return *this;
    }
};

template<typename T>
KernelMap(std::initializer_list<std::pair<const char*,T>> l)
    -> KernelMap<std::string,T>;

template<typename Platform, typename V, typename E, typename... Args>
struct TemplateConfig : public AlgorithmConfig
{
  using Vertex = V;
  using Edge = E;
  using KernelType = GraphKernel<Platform,V,E,Args...>;
  using ConfigArg = std::shared_ptr<KernelType>;

  template<typename T>
  using alloc_t = typename Platform::template alloc_t<T>;

  static constexpr bool isSwitching = false;

  protected:
    Platform& backend;
    size_t vertex_count, edge_count;
    std::shared_ptr<GraphKernel<Platform,V,E,Args...>> kernel;

    GraphLoader<Platform,V,E> loader;

    TemplateConfig(ConfigArg kern)
    : backend(Platform::get()), kernel(kern)
    {}

    void setKernelConfig(std::shared_ptr<KernelType> k)
    {
        auto div = getWorkDivision(k->workDivision);
        auto sharedMem = k->getSharedMemSize(div.first);
        backend.setWorkSizes(1, {div.first}, {div.second}, sharedMem);
    }

    void setKernelConfig(work_division w, size_t sharedMem = 0)
    {
        auto div = getWorkDivision(w);
        backend.setWorkSizes(1, {div.first}, {div.second}, sharedMem);
    }

    virtual void loadGraph(const Graph<V,E>& graph)
    { loader.loadGraph(graph, kernel->representation); }

    virtual void transferGraph()
    { loader.transferGraph(kernel->representation); }

    void loadGraph(const std::string filename) override final
    {
        Timer graphTransfer("graphTransfer", run_count);
        Graph<V,E>& graph(filename);

        loadGraph(graph);

        vertex_count = graph.vertex_count;
        edge_count = graph.edge_count;
        vertexDivision = backend.computeDivision(vertex_count);
        edgeDivision = backend.computeDivision(edge_count);

        graphTransfer.start();
        transferGraph();
        graphTransfer.stop();
    }

    void freeGraph() override final
    { loader.freeGraph(); }

  private:
    std::pair<size_t,size_t> vertexDivision, edgeDivision;

    const std::pair<size_t,size_t>&
    getWorkDivision(work_division w)
    {
        switch (w) {
            case work_division::edge: return edgeDivision;
            case work_division::vertex: return vertexDivision;
        }
    }
};

template<typename Platform, typename V, typename E, typename... Args>
struct WarpConfig : public TemplateConfig<Platform,V,E,Args...>
{
    using Config = TemplateConfig<Platform,V,E,Args...>;
    using Config::options;
    using KernelType = WarpKernel<Platform,V,E,Args...>;
    using ConfigArg = std::shared_ptr<KernelType>;

    std::function<void()> setWarpConfig;

    WarpConfig(ConfigArg kernel)
    : Config(kernel), warp_size(32), chunk_size(32)
    {
        options.add('w', "warp", "NUM", warp_size,
                    "Virtual warp size for warp variants.")
               .add('c', "chunk", "NUM", chunk_size,
                    "Work chunk size for warp variants.");

        setWarpConfig = [kernel,this]() {
            kernel->warp_size = std::ref(warp_size);
            kernel->chunk_size = std::ref(chunk_size);
        };
    }

  private:
    virtual void prepareRun() override final
    { setWarpConfig(); }

    size_t warp_size, chunk_size;
};

template
< template<typename, typename...> class Cfg
, typename Platform
, typename Vertex
, typename Edge
, typename... KernelArgs
, typename... Args
, typename Base = TemplateConfig<Platform,Vertex,Edge,KernelArgs...>
, typename WarpBase = WarpConfig<Platform,Vertex,Edge,KernelArgs...>
, typename Config = Cfg<Base,Args...>
, typename WarpConfig = Cfg<WarpBase,Args...>
>
AlgorithmConfig*
make_config
( std::shared_ptr<GraphKernel<Platform,Vertex,Edge,KernelArgs...>> k
, Args... args
)
{
    typedef WarpKernel<Platform,Vertex,Edge,KernelArgs...> WarpKernel;

    if (auto kern = std::dynamic_pointer_cast<WarpKernel>(k)) {
        return new WarpConfig(kern, args...);
    } else {
        return new Config(k, args...);
    }
}

template<typename Platform, typename V, typename E, typename... Args>
struct SwitchConfig;

class prop_ref : public std::reference_wrapper<double>
{
    static double dummyProp;

  public:
    prop_ref(prop_ref&&) = delete;
    prop_ref(const prop_ref&) = delete;

    prop_ref(const std::string&, AlgorithmConfig&)
     : std::reference_wrapper<double>(dummyProp)
    {}

    template<typename Platform, typename V, typename E, typename... Args>
    prop_ref
        ( const std::string& name
        , SwitchConfig<Platform,V,E,Args...>& cfg
        , bool graphProp = false
        )
        : std::reference_wrapper<double>(dummyProp)
    {
        if (graphProp) cfg.graphProperties.emplace(name, std::ref(*this));
        else cfg.algorithmProperties.emplace(name, std::ref(*this));
    }

    prop_ref& operator=(const std::reference_wrapper<double>& val)
    { std::reference_wrapper<double>::operator=(val); return *this; }

    double& operator=(const double& val)
    { return this->get() = val; }

    void reset()
    { operator=(std::ref(dummyProp)); }
};

double prop_ref::dummyProp = 0;

template<typename Platform, typename V, typename E, typename... Args>
struct SwitchConfig : public TemplateConfig<Platform,V,E,Args...>
{
    using Config = TemplateConfig<Platform,V,E,Args...>;
    using KernelType = typename Config::KernelType;
    using WarpKernelType = typename Config::KernelType::WarpVersion;
    using ConfigArg = KernelMap<std::string,std::shared_ptr<KernelType>>;
    using Config::kernel;
    using Config::loader;
    using Config::options;
    using Config::setKernelConfig;

    typedef std::set<std::string> prop_set;

    friend prop_ref;

    static constexpr bool isSwitching = true;

    class graph_prop
    {
        graph_prop(graph_prop&&) = delete;
        graph_prop(const graph_prop&) = delete;

        prop_ref absProp, inProp, outProp;

      public:
        graph_prop(std::string prefix, std::string suffix, SwitchConfig& cfg)
         : absProp(prefix + "abs" + suffix, cfg, true)
         , inProp(prefix + "in" + suffix, cfg, true)
         , outProp(prefix + "out" + suffix, cfg, true)
        {}

        prop_ref& operator[](Degrees deg)
        {
            switch (deg) {
                case Degrees::abs: return absProp;
                case Degrees::in: return inProp;
                case Degrees::out: return outProp;
            }
        }
    };

    struct implementation
    {
        implementation() : kernel(nullptr), warp_size(32), chunk_size(32)
        {}

        implementation(std::shared_ptr<KernelType> k, size_t w, size_t c)
         : kernel(k), warp_size(w), chunk_size(c)
        {}

        std::shared_ptr<KernelType> kernel;
        size_t warp_size;
        size_t chunk_size;
    };

    SwitchConfig(std::map<std::string,std::shared_ptr<KernelType>> ks)
    : Config(nullptr)
    , modelHandle(nullptr)
    , kernelMap(ks)
    , vertices("vertex count", *this, true)
    , edges("edge count", *this, true)
    , min("min ", " degree", *this)
    , lowerQuantile("lower quantile ", " degree", *this)
    , mean("mean ", " degree", *this)
    , median("median ", " degree", *this)
    , upperQuantile("upper quantile ", " degree", *this)
    , max("max ", " degree", *this)
    , stdDev("stddev ", " degree", *this), warp_size(32), chunk_size(32)
    {
        options.add('m', "model", "FILE", model, "Prediction model to use.");
        options.add('l', "log", "FILE", logFile, "Where to log properties.");
    }

    virtual void loadGraph(const Graph<V,E>& graph) override
    {
        vertices = graph.vertex_count;
        edges = graph.edge_count;

        for (const auto& type : { Degrees::abs, Degrees::in, Degrees::out }) {
            auto summary = graph.degreeStatistics(type);

            min[type] = summary.min;
            lowerQuantile[type] = summary.lowerQuantile;
            mean[type] = summary.mean;
            median[type] = summary.median;
            upperQuantile[type] = summary.upperQuantile;
            max[type] = summary.max;
            stdDev[type] = summary.stdDev;
        }

        std::vector<GraphRep> reps;
        for (auto& impl : implementations) {
            reps.push_back(impl.kernel->representation);
        }
        loader.loadGraph(graph, reps);
    }

    virtual void transferGraph() override
    {
        for (auto& impl : implementations) {
            loader.transferGraph(impl.kernel->representation);
        }
    }

  protected:
    void predictInitial()
    {
        stepNum = 0;
        logGraphProps();
        logAlgorithmProps();

        lastKernel = lookup();
        if (lastKernel == -1) lastKernel = defaultKernel;

        auto& impl = implementations[static_cast<size_t>(lastKernel)];
        kernel = impl.kernel;
        warp_size = impl.warp_size;
        chunk_size = impl.chunk_size;
        setKernelConfig(kernel);
    }

    void predict()
    {
        ++stepNum;
        logAlgorithmProps();

        int32_t result = lookup();
        if (result != -1 && result != lastKernel) {
            auto& impl = implementations[static_cast<size_t>(result)];
            kernel = impl.kernel;
            warp_size = impl.warp_size;
            chunk_size = impl.chunk_size;
            setKernelConfig(kernel);
            lastKernel = result;
        }
    }

    virtual void prepareRun() override final
    {
        prop_set missingGraphProps;
        prop_set missingAlgoProps;

        for (auto& pair : graphProperties) {
            auto& [name, val] = pair;
            missingGraphProps.insert(name);
        }

        for (auto& pair : algorithmProperties) {
            auto& [name, val] = pair;
            missingAlgoProps.insert(name);
        }

        if (!model.empty()) {
            setupPredictor(model.c_str(), missingGraphProps, missingAlgoProps);
        } else {
            lookup = []() { return -1; };

            try {
                kernel = kernelMap.at("edge-list");
            } catch (const std::out_of_range&) {
            }

            implementations.emplace_back(kernel, 0, 0);
        }

        if (!logFile.empty()) {
            setupLogging(missingGraphProps, missingAlgoProps);
        } else {
            logGraphProps = [](){};
            logAlgorithmProps = [](){};
        }

        if (kernel == nullptr) {
            reportError("No edge list implementation found!");
        }
    }

    virtual void cleanupRun() override final
    {
        implementations.clear();

        if (modelHandle) {
            int result = dlclose(modelHandle);
            if (result) reportError("dlclose() failed!\n", dlerror());
            modelHandle = nullptr;
        }

        if (!logFile.empty()) propLog = std::ofstream();

        for (auto& pair : graphProperties) {
            auto& [name, prop] = pair;
            prop.get().reset();
        }

        for (auto& pair : algorithmProperties) {
            auto& [name, prop] = pair;
            prop.get().reset();
        }
    }

  private:
    void
    setupPredictor
    (const char * const lib, prop_set& graphProps, prop_set& algoProps)
    {
        typedef std::tuple<std::string,size_t,size_t,size_t> impl_tuple;
        typedef std::reference_wrapper<double> double_ref;
        typedef const std::vector<impl_tuple> implementations_t;
        typedef const std::map<std::string,double_ref> properties;

        modelHandle = dlopen(lib, RTLD_NOW);
        if (!modelHandle) {
            reportError("dlopen() failed: ", lib, "\n", dlerror());
        }

        lookup = safe_dlsym<int32_t()>(modelHandle, "lookup");
        auto& impls = *safe_dlsym<implementations_t>(modelHandle, "implNames");
        auto& params = *safe_dlsym<properties>(modelHandle, "propNames");

        bool missing = false;
        for (auto& pair : params) {
            auto& [name, prop] = pair;
            try {
                graphProperties[name] = prop;
                graphProps.erase(name);
            } catch (const std::out_of_range&) {
                try {
                    algorithmProperties[name] = prop;
                    algoProps.erase(name);
                } catch (const std::out_of_range&) {
                    std::cerr << "Missing property: " << name << std::endl;
                    missing = true;
                }
            }
        }

        implementations.resize(impls.size());
        for (auto& data : impls) {
            auto& [ name, idx, warp, chunk ] = data;
            try {
                implementations[idx] = { kernelMap.at(name), warp, chunk };
                if (auto kern = std::dynamic_pointer_cast<WarpKernelType>(implementations[idx].kernel)) {
                    kern->warp_size = std::ref(warp_size);
                    kern->chunk_size = std::ref(chunk_size);
                }
                if (name == "edge-list") {
                    kernel = implementations[idx].kernel;
                    defaultKernel = static_cast<int32_t>(idx);
                }
            } catch (const std::out_of_range&) {
                std::cerr << "Missing implementation: " << name << std::endl;
                missing = true;
            }
        }

        if (missing) reportError("Missing properties/implementations!");
    }

    void setupLogging(prop_set& missingGraphProps, prop_set& missingAlgoProps)
    {
        propLog = std::ofstream(logFile);
        propLog.imbue(std::locale("C"));
        lookup = [this,oldPredictor{lookup}]() {
            int32_t result = oldPredictor();
            propLog << "prediction:" << stepNum << ":" << result
                    << std::endl;
            return result;
        };

        std::vector<std::pair<std::string,double>> graphProps;
        graphProps.reserve(missingGraphProps.size());

        for (auto& name : missingGraphProps) {
            graphProps.emplace_back(name, 0);
            graphProperties[name] = std::ref(graphProps.back().second);
        }

        logGraphProps = [this,props{std::move(graphProps)}]() {
            for (auto& pair : graphProperties) {
                auto& [name, ref] = pair;
                propLog << "graph:" << name << ":" << ref.get()
                        << std::endl;
            }
        };

        std::vector<std::pair<std::string,double>> algoProps;
        algoProps.reserve(missingAlgoProps.size());

        for (auto& name : missingAlgoProps) {
            algoProps.emplace_back(name, 0);
            algorithmProperties[name] = std::ref(algoProps.back().second);
        }

        logAlgorithmProps = [this,props{std::move(algoProps)}]() {
            for (auto& pair : algorithmProperties) {
                auto& [name, ref] = pair;
                propLog << "step:" << stepNum << ":" << name << ":"
                        << ref.get() << std::endl;
            }
        };
    }

    std::string logFile;
    std::string model;

    void *modelHandle;
    std::function<int32_t()> lookup;

    std::ofstream propLog;
    std::function<void()> logGraphProps;
    std::function<void()> logAlgorithmProps;

    int32_t lastKernel;
    int32_t defaultKernel;

    std::vector<implementation> implementations;
    std::map<std::string,std::shared_ptr<KernelType>> kernelMap;

    refmap<std::string,prop_ref> graphProperties;
    refmap<std::string,prop_ref> algorithmProperties;

    prop_ref vertices, edges;
    graph_prop min, lowerQuantile, mean, median, upperQuantile, max, stdDev;
    size_t stepNum, warp_size, chunk_size;
};

template
< template<typename, typename...> class Cfg
, typename Platform
, typename Vertex
, typename Edge
, typename... KernelArgs
, typename... Args
, typename Base = SwitchConfig<Platform,Vertex,Edge,KernelArgs...>
, typename Config = Cfg<Base,Args...>
>
AlgorithmConfig*
make_switch_config
( KernelMap<std::string,std::shared_ptr<GraphKernel<Platform,Vertex,Edge,KernelArgs...>>> ks
, Args... args
)
{ return new Config(ks, args...); }
#endif
