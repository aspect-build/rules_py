#ifndef UV_SDIST_CC_DEPS_PROBE_H_
#define UV_SDIST_CC_DEPS_PROBE_H_

#ifdef __cplusplus
extern "C" {
#endif

// Returns a constant probe value. Present only so the `cc_deps` override has a
// real CcInfo target to reference; the snapshot never builds this library.
int rules_py_cc_deps_probe(void);

#ifdef __cplusplus
}
#endif

#endif  // UV_SDIST_CC_DEPS_PROBE_H_
