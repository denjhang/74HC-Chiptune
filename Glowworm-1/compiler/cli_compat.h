//==============================================================================
// cli_compat.h —— 萤火虫编译器命令行版 MFC 兼容 shim
//------------------------------------------------------------------------------
// 龙少的 GlowCompiler 是 MFC GUI 程序，源码里散用 CString / _T() / WIN32 API。
// 命令行版不依赖 MFC，本头提供最小兼容：
//   * CString：最小字符串类，支持 += / Format / = (const char*)
//   * _T(x)   ：映射为 x
//   * 必要的 windows.h typedef（FALSE / TRUE 等）
//
// 原始 lcc + glow.cpp 代码 0 修改即可用 g++ 编译（GUI 文件除外）。
//==============================================================================
#ifndef CLI_COMPAT_H
#define CLI_COMPAT_H

#include <string>
#include <cstdarg>
#include <cstdio>
#include <cstdint>
#include <climits>

// MSVC ↔ mingw 宏别名（dag.cpp / lex.cpp 用 MSVC 名）
#ifndef LONGLONG_MAX
#define LONGLONG_MAX   LONG_LONG_MAX
#endif
#ifndef LONGLONG_MIN
#define LONGLONG_MIN   LONG_LONG_MIN
#endif
#ifndef ULONGLONG_MAX
#define ULONGLONG_MAX  ULONG_LONG_MAX
#endif

// ---------- 基本 Win32 宏 ----------
#ifndef FALSE
#define FALSE 0
#endif
#ifndef TRUE
#define TRUE 1
#endif

// _T(x) 宏：MFC 的 TCHAR 文本映射
#ifndef _T
#define _T(x) x
#endif

// ---------- CString 最小 shim ----------
// glow.cpp 里 CString 只用到：构造、=、+=、Format、+（字符串拼接）
class CString {
public:
    std::string s;

    CString() {}
    CString(const char* str) : s(str ? str : "") {}
    CString(const std::string& str) : s(str) {}

    // 赋值
    CString& operator=(const char* str)       { s = str ? str : ""; return *this; }
    CString& operator=(const CString& o)      { s = o.s; return *this; }
    CString& operator=(const std::string& o)  { s = o; return *this; }

    // 拼接 +=
    CString& operator+=(const char* str)       { if (str) s += str; return *this; }
    CString& operator+=(const CString& o)      { s += o.s; return *this; }
    CString& operator+=(const std::string& o)  { s += o; return *this; }
    CString& operator+=(char c)                { s += c; return *this; }

    // + （返回新 CString）
    CString operator+(const char* str) const       { CString r(*this); if (str) r.s += str; return r; }
    CString operator+(const CString& o) const      { CString r(*this); r.s += o.s; return r; }
    CString operator+(const std::string& o) const  { CString r(*this); r.s += o; return r; }

    // 比较
    bool operator==(const char* str) const     { return s == (str ? str : ""); }
    bool operator==(const CString& o) const    { return s == o.s; }
    bool operator!=(const char* str) const     { return !(*this == str); }

    // CString 隐式转 const char* （glow.cpp 里有 (CString)xxx 强转用法）
    operator const char*() const { return s.c_str(); }

    // Format：MFC 的 printf 风格格式化（覆盖原内容）
    void Format(const char* fmt, ...) {
        va_list ap; va_start(ap, fmt);
        char buf[4096];
        vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        s = buf;
    }
    // 重载：Format(CString, ...) 用于 glow.cpp 的 redirect_addr_err->Format(*redirect_addr_err + _T("..."), ...)
    //       实际它先算 *err + "..." 得 CString 再 Format，本质和上面一样
    void Format(const CString& base, const char* fmt, ...) {
        va_list ap; va_start(ap, fmt);
        char buf[4096];
        vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        s = std::string(base.s) + buf;
    }

    // 常用方法
    const char* c_str() const { return s.c_str(); }
    size_t      GetLength() const { return s.size(); }
    bool        IsEmpty() const { return s.empty(); }
    void        Empty() { s.clear(); }
};

#endif // CLI_COMPAT_H
