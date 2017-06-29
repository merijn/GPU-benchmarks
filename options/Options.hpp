#ifndef __OPTIONS_HPP__
#define __OPTIONS_HPP__

#include <functional>
#include <iostream>
#include <map>
#include <set>
#include <string>
#include <vector>

class Options {
    class Option {
        friend class Options;

        char shortOption;
        const char *longOption;
        std::function<void(const char *)> action;
        std::string argName;
        std::string helpString;
        std::string defaultVal;

        bool hasArg;
        bool multiFlag;

        Option() : Option('\0', "", [](auto){}, "", "")
        {}

        Option
        ( char shortOpt
        , const char *longOpt
        , std::function<void(const char *)> act
        , std::string arg
        , std::string help
        ) : shortOption(shortOpt), longOption(longOpt), action(act), argName(arg)
        , helpString(help), defaultVal(""), hasArg(false), multiFlag(false)
        {}
    };

    std::set<char> reservedShort;
    std::set<std::string> reservedLong;

    std::ostream &usageOutput;
    std::function<void(std::ostream&)> usagePreamble;
    Option usageFlag;
    bool hasUsage;

    std::map<int, Option> options;

    std::vector<char *> parseArgs(int, char **, bool);

    void setReserved(const Options& other)
    {
        reservedShort = other.reservedShort;
        reservedLong = other.reservedLong;

        for (auto kv : other.options) {
            auto opt = kv.second;
            reservedShort.emplace(opt.shortOption);
            reservedLong.emplace(opt.longOption);
        }
    }

  public:
    Options() : usageOutput(std::cerr), hasUsage(false)
    {}

    Options(const Options& other, bool dontDefaultConstruct)
     : usageOutput(std::cerr), hasUsage(false)
    {
        (void) dontDefaultConstruct;
        setReserved(other);
    }

    Options
    ( char c
    , const char *l
    , std::ostream &out
    , std::function<void(std::ostream&)> f
    ) : usageOutput(out), usagePreamble(f), hasUsage(true)
    {
        usageFlag.shortOption = c;
        usageFlag.longOption = l;
        usageFlag.helpString = "This help.";
    }

    Options
    ( const Options& other
    , char c
    , const char *l
    , std::ostream &out
    , std::function<void(std::ostream&)> f
    ) : Options(c, l, out, f)
    { setReserved(other); }

    Options& add(Option o);
    Options& add(char, const char *, std::string, std::string &, std::string);

    template<typename T>
    Options& add(char so, const char *lo, T& var, T val, std::string help)
    { return add(Option(so, lo, [&,val](auto) { var = val; }, "", help)); }

    template<typename T>
    Options& add
        ( char so
        , const char *lo
        , std::string arg
        , T& var
        , std::string help
        , typename std::enable_if<std::is_integral<T>::value>::type* = nullptr)
    {
        auto action = [&](auto s) { var = static_cast<T>(std::stoi(s)); };
        auto opt = Option(so, lo, action, arg, help);
        opt.defaultVal = std::to_string(var);
        opt.hasArg = true;
        return add(opt);
    }

    template<typename T>
    Options& add
    ( char so
    , const char *lo
    , std::string arg
    , std::vector<T>& var
    , std::string def
    , std::string help
    , std::function<T(const char *)> fun = [](auto s) { return s; }
    )
    {
        auto action = [&](auto s) { var.push_back(fun(s)); };
        auto opt = Option(so, lo, action, arg, help);
        opt.defaultVal = def;
        opt.hasArg = true;
        opt.multiFlag = true;
        return add(opt);
    }

    std::vector<char *> parseArgs(std::vector<char *>&);
    std::vector<char *> parseArgs(int, char **);

    std::vector<char *> parseArgsFinal(std::vector<char *>&);
    std::vector<char *> parseArgsFinal(int, char **);

    void usage(std::ostream&, std::string = "");
};
#endif