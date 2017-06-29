#ifndef __UTIL_HPP__
#define __UTIL_HPP__

#include <cstdio>
#include <cstdlib>
#include <cxxabi.h>
#include <dlfcn.h>
#include <execinfo.h>

#include <atomic>
#include <iostream>
#include <map>
#include <memory>
#include <string>

#ifdef __clang__
#define FALLTHROUGH [[clang::fallthrough]]
#else
#define FALLTHROUGH
#endif

struct AlgorithmConfig;
class Options;

typedef void kernel_register_t
    ( std::map<std::string, AlgorithmConfig*>& kernels
    , const Options&
    , size_t run_count);

constexpr std::size_t operator "" _sz (unsigned long long int x);
constexpr std::size_t operator "" _sz (unsigned long long int x)
{ return x; }

template<typename T>
bool atomic_max(std::atomic<T>& max, T const& val) noexcept;

template<typename T>
bool atomic_max(std::atomic<T>& max, T const& val) noexcept
{
    bool r;
    T prev = max;
    while (prev < val && !(r = max.compare_exchange_weak(prev, val)));
    return r;
}

template<typename T>
bool atomic_min(std::atomic<T>& min, T const& val) noexcept;

template<typename T>
bool atomic_min(std::atomic<T>& min, T const& val) noexcept
{
    bool r;
    T prev = min;
    while (prev > val && !(r = min.compare_exchange_weak(prev, val)));
    return r;
}

void __attribute__((noreturn)) out_of_memory(void);
void __attribute__((noreturn)) dump_stack_trace(int exit_code);

void printVals(void);

template<typename T, typename... Args>
inline void
printVals(T v, Args... args)
{
    std::cerr << v;
    printVals(args...);
}

template<typename... Args>
inline void __attribute__((noreturn))
reportError(Args... args)
{
    printVals(args...);
    std::cerr << std::endl;
    exit(EXIT_FAILURE);
}

template<typename... Args>
inline void __attribute__((noreturn))
stackTraceError(Args... args)
{
    reportError(args...);
    dump_stack_trace(EXIT_FAILURE);
}

template<typename... Args>
inline void
checkError(bool cond, Args... args)
{
    if (cond) return;
    reportError(args...);
}

template<typename C>
class simple_iterator : public C::const_iterator {
    typedef typename C::const_iterator parent_type;
    parent_type end;

    public:
        simple_iterator(const C& c)
            : parent_type(c.cbegin())
            , end(c.cend())
        {}

        explicit operator bool() const
        { return *this != end; }
};

template<typename C>
simple_iterator<C> make_simple_iterator(const C& val);

template<typename C>
simple_iterator<C> make_simple_iterator(const C& val)
{ return simple_iterator<C>(val); }

template<typename T>
class shared_array : public std::shared_ptr<void> {
    public:
      shared_array(void* data, std::function<void(void*)> deleter)
      : std::shared_ptr<void>(data, deleter)
      {}

      template<typename Ptr>
      shared_array(const shared_array<Ptr>& ptr, void* data)
      : std::shared_ptr<void>(ptr, data)
      {}

      T& operator[](size_t n)
      { return static_cast<T*>(this->get())[n]; }

      const T& operator[](size_t n) const
      { return static_cast<T*>(this->get())[n]; }

      template<typename Ptr>
      operator Ptr*() const { return static_cast<Ptr*>(this->get()); }
};
#endif