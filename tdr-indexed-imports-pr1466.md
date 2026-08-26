# TDR — Indexed Imports en rules_py

**PR:** [aspect-build/rules_py#1466](https://github.com/aspect-build/rules_py/pull/1466) — `perf(py): index Python imports in runtime venvs`
**Autor:** `zbarsky-openai` · **Base:** `main` · **Tamaño:** +1,242 / −293 en 18 archivos
**Flag:** `--@aspect_rules_py//py:experimental_indexed_imports` (default `False`)
**Fecha del análisis:** 2026-08-19 · **Revisor:** Abel (maintainer, aspect_rules_py)

---

## 1. Resumen ejecutivo

El PR reemplaza, de forma opt-in y solo para **venvs privados** (los internos de `py_binary` / `py_test`), la proyección física de symlinks por-paquete dentro de `site-packages` por:

1. **Una acción de build por venv** (`PyImportIndex`) que genera un índice TSV mapeando cada nombre importable de nivel superior a su root dueño (wheel o directorio first-party).
2. **Un finder custom en `sys.meta_path`** (`_IndexedImportFinder`) instalado por el `.pth` del venv, que resuelve cada import consultando el índice y delegando la carga real en el `PathFinder` estándar de CPython, sin poner los roots virtualizados en `sys.path`.

El objetivo es romper la escala O(targets × paquetes) en número de acciones y outputs declarados. Los números reportados por el autor (monorepo grande, presumiblemente OpenAI): **−56% acciones** en configuración compatible, **−74%** en configuración full, **−7% wall time** de builds analysis-only, **−6% memoria pico**, y ~127 ms para construir un índice de ~37,000 records incluyendo el arranque del intérprete.

Los venvs **públicos** (`py_venv`, `expose_venv = True`) permanecen físicos siempre. Cada target puede optar por salir con `indexed_imports = False`.

---

## 2. Terminología

Glosario de los términos que este documento y el código usan. Las definiciones marcadas **(PR)** son introducidas por el cambio.

| Término | Definición |
|---|---|
| **venv privado** | El venv hermano `_<name>.venv` que la macro `py_binary_with_venv` emite para cada `py_binary`/`py_test` sin `expose_venv`. Es una regla no-ejecutable (`_py_venv_lib`), `visibility:private`, `tags:manual`. Solo el launcher del binario lo consume. |
| **venv público** | El target `<name>.venv` emitido con `expose_venv = True`, o un `py_venv` standalone. Es ejecutable (`bazel run` abre un REPL) y su layout físico es contrato para IDEs/typecheckers vía `py_venv_link`. |
| **proyección (projection)** | Un symlink declarado dentro del `site-packages` del venv apuntando (escapando por runfiles) al contenido de un wheel. Hoy: un `ctx.actions.declare_symlink` + `ctx.actions.symlink` por entrada de `top_level_to_site_pkgs`. |
| **top-level** | Entrada inmediata del `site-packages` de un wheel: un paquete (`requests/`), un módulo (`six.py`), una extensión nativa (`_x.cpython-312-….so`), o metadata (`*.dist-info`). |
| **`PyWheelsInfo`** | Provider (`py/private/providers.bzl`) con un depset postorder de *wheel records*: layout (`top_levels`, `namespace_*`, `regular_roots`, `native_roots`), `site_packages_rfpath`, `install_tree`, `console_scripts`, `data_files`, y claims precomputados (`tl_claims`, `metadata_top_levels`, `cs_claims`). |
| **`site_packages_rfpath`** | Path relativo al runfiles root del `site-packages` de un wheel instalado (p.ej. `rules_py~~uv~pkg_312_requests/site-packages/lib/python3.12/site-packages`). Es la identidad de un wheel en toda la resolución de colisiones. |
| **`install_tree`** | Tree artifact con el árbol instalado completo del wheel (output de la acción de unpack de `whl_install`). |
| **claimant / claim** | Struct por (wheel, top-level) con los hechos de ese top-level (`is_ns`, `is_dir`, `is_native`, `ns_entries`, `ns_dirs`). La resolución de colisiones opera sobre listas de claimants por nombre. |
| **namespace package (PEP 420)** | Paquete sin `__init__.py` cuyo `__path__` une contribuciones de múltiples `sys.path` entries. En rules_py se materializa con symlinks por-entrada (`google/cloud/storage → wheel A`, `google/cloud/bigquery → wheel B`). |
| **regular root** | Directorio mínimo bajo un namespace top-level que sí lleva `__init__.py`. Si dos wheels aportan al mismo regular root, Python fija `__path__` al primero que encuentra → hace falta **merge físico**. |
| **native root** | Root en conflicto que contiene entradas nativas (`.so`/`.dylib`/`.pyd`). No se puede copiar a un merge sin cambiar el origen físico de la librería → se resuelve por proyección directa del último claimant regular. |
| **merge group / `PySiteMerge`** | Acción que copia el subárbol de un regular package desde cada wheel contribuyente a un directorio real del venv (el layout que produciría `pip install` plano). Corre bajo el intérprete del exec toolchain. |
| **`.pth` fallback (whole-wheel fallback)** | Línea del `.pth` del venv que pone el `site-packages` completo de un wheel en `sys.path`. Es el mecanismo para wheels sin layout proyectable o para claimants perdedores de una colisión. |
| **fully covered** | Wheel cuyo `site-packages` puede salirse del `.pth` fallback porque cada top-level suyo quedó proyectado, mergeado o suprimido. Condición necesaria para virtualizarlo **(PR)**. |
| **known layout** | Wheel que declara `top_levels` (layout derivado de RECORD). Un wheel source-built de layout desconocido deja `top_levels` vacío y vive solo del fallback `addsitedir`. |
| **`imports_depset`** | Depset de import roots: paths first-party (`_main/src/...`) + los `site_packages_rfpath` de los wheels. Hoy se serializa línea a línea al `.pth`. |
| **escape / `venv_to_runfiles_escape`** | Aritmética de `../` para escapar desde `site-packages` (o desde el root del venv) hasta el runfiles root. Calculada por `resolve_venv_toolchain`. |
| **indexed imports (PR)** | El modo nuevo: proyecciones de wheels seguras se reemplazan por records del índice; los import roots first-party reclamados salen de `sys.path` y se resuelven vía finder. |
| **root virtual (PR)** | Import root que existe solo en el índice — nunca entra a `sys.path`. Kinds `F` (first-party) y los roots de wheels en records `I`/`D`. |
| **root retenido (PR)** | Import root que conserva su línea física en el `.pth` (kind `K`) o su `addsitedir` (kind `X`). |
| **shim (PR)** | `_aspect_rules_py_import_index.py`, copiado al `site-packages` del venv; define e instala `_IndexedImportFinder` al ser importado por el `.pth`. |
| **RBE** | Remote Build Execution. Relevante: la acción nueva declara `supports-path-mapping` y consume solo *paths*, no contenidos. |

---

## 3. Arquitectura actual (baseline)

### 3.1 Pipeline de wheels: del registry al provider

```
PyPI/registry
   │  (repository rule: whl_dist — uv/private/whl_install/dist_repository.bzl)
   ▼
descarga wheel + peek de RECORD y entry_points.txt
   │  extract_install_metadata() → derive_layout()   (metadata.bzl)
   ▼
repo @whl__pkg__hash: atributos de layout serializados en el BUILD generado
   │  (regla whl_dist / whl_install — uv/private/whl_install/rule.bzl)
   ▼
acción de unpack → install_tree (tree artifact)
   │  make_wheel_record()   (py/private/providers.bzl)
   ▼
PyWheelsInfo.wheels  (depset postorder de wheel records)
```

Puntos clave:

- **`derive_layout`** clasifica cada top-level de RECORD: regular vs namespace (¿hay `<tl>/__init__.py`?), esqueleto de directorios namespace, regular roots mínimos, native roots. Esta clasificación es la que hace posible decidir *en análisis* qué es seguro symlinkear, qué se mergea y qué cae al fallback.
- **`exclude_glob`** (baseline): la extracción del repo es agnóstica a exclusiones; cuando un paquete consumidor declara `exclude_glob`, el wheel carga `record_paths` completos y `whl_install` filtra y **re-deriva** el layout en análisis.
- El orden postorder del depset define la precedencia de colisiones: "último claimant distinto gana".

### 3.2 De `py_binary` al venv hermano

`py_binary` / `py_test` son macros (`py_binary_with_venv`, `py_venv.bzl:362`) que dividen cada invocación en:

- un venv hermano — privado (`_<name>.venv`, regla `_py_venv_lib`, no ejecutable) o público (`<name>.venv`, regla `py_venv`) según `expose_venv`;
- la regla launcher (`py_binary`/`py_test`) que lo consume vía el atributo interno `venv` y hace exec de `<venv>/bin/python -I main.py`.

Todos los atributos que dan forma al venv (`deps`, `imports`, `virtual_deps`, `resolutions`, `package_collisions`, …) viven en `_VENV_ONLY_ATTRS` y se rutean al hermano. **Esto importa para el PR**: el atributo nuevo `indexed_imports` se agrega a esa lista y por lo tanto fluye del macro al venv.

### 3.3 `assemble_venv`: el layout físico

`assemble_venv` (`py/private/py_venv/venv.bzl`) es el único lugar que declara los archivos de un venv. Produce, por venv:

| Artefacto | Mecanismo | Cardinalidad |
|---|---|---|
| Symlink por top-level proyectado | `declare_symlink` + `ctx.actions.symlink`, target relativo `escape/<sp_rfpath>/<tl>` | **O(top-levels del closure)** |
| Symlinks de data files PEP 427 (`share/…`, `etc/…`) | ídem, bajo el prefix del venv | O(data files colapsados) |
| Merges físicos de regular packages que cruzan wheels | acción `PySiteMerge` (intérprete exec-config) | O(merge groups) |
| `<venv_stem>.pth` | `ctx.actions.write` con `Args` param-file (`map_each = _format_imp`) | 1 |
| `pyvenv.cfg` | `ctx.actions.write` | 1 |
| `bin/python` + versionados | `declare_symlink` | ~3 |
| `bin/activate`, `bin/<console_script>` | `expand_template` | 1 + O(scripts) |

La primera fila es el problema de escala: **cada binario y cada test del repo re-declara un symlink por cada top-level de cada wheel de su closure**. Con cientos de targets compartiendo los mismos ~500 wheels, la cantidad de outputs declarados, acciones symlink y nodos Skyframe crece multiplicativamente.

### 3.4 `resolve_wheel_collisions`: las clases de colisión

`virtuals_resolvers.bzl` recorre los wheel records y produce el plan. Clases y resoluciones (baseline):

| Clase | Resolución | Destino de los perdedores |
|---|---|---|
| Top-level de un solo claimant | proyección directa | — |
| Todos namespace, sin conflicto de regular roots | symlinks por-entrada (`_resolve_pure_namespace`), colapsados al cover más grueso de un solo dueño | claimants sin `ns_entries` → `.pth` fallback |
| Todos namespace, con regular root cruzando wheels | root mergeable → `PySiteMerge`; root nativo → proyección directa del último claimant regular (`_resolve_native_span`) | `.pth` fallback (salvo dup-metadata) |
| Directorios ordinarios en colisión, sin nativos | merge físico `PySiteMerge` | — (todos contribuyen) |
| Directorios con nativos / archivos ordinarios | último claimant distinto gana | `.pth` fallback |
| Metadata `*.dist-info` duplicada | último gana; **`fail`** si un perdedor queda en fallback (expondría metadata duplicada insuprimible) | — |
| Console scripts | último claimant distinto gana | — |
| Data files | por-archivo, último gana; roots del venv (`bin`, `lib`, `pyvenv.cfg`) reservados; colapso al cover más grueso | drop reportado |

Todo pasa por el recorder de colisiones y `enforce_collision_policy` aplica `error`/`warning`/`ignore`.

Al final, `_compute_fully_covered` determina qué wheels pueden salir del `.pth`: en baseline, un wheel es fully covered si **cada** top-level suyo está `skipped`-free y además es dueño o fue marcado `covered` (proyectado/mergeado/suprimido) — tracking explícito vía `covered_per_wheel`.

### 3.5 El `.pth` y por qué su contenido es delicado

El `.pth` generado hoy contiene, en orden:

1. `escape` — el runfiles root entra a `sys.path`.
2. Una línea ejecutable que antepone `<venv>/bin` a `$PATH` (console scripts alcanzables vía `subprocess.run("name")` sin cargar distutils).
3. Por cada import del `imports_depset`:
   - wheel fully covered → **nada** (se suprime);
   - `site-packages` de layout desconocido → línea `site.addsitedir(..., vars().get("known_paths"))` — el truco de reusar el set de `site.addpackage` evita el costo O(N²) de stats que domina el arranque cuando hay cientos de líneas;
   - resto → path plano `escape/<imp>`.

Nota de arquitectura: el `.pth` es hoy el **único** mecanismo de fallback universal. El orden de sus líneas es la precedencia de `sys.path`, byte a byte.

### 3.6 Modelo de costo del baseline

Para un repo con `T` binarios/tests y closures promedio de `P` top-levels de wheels:

- **Outputs declarados / acciones symlink:** ~`T × P` (cada una es barata individualmente, pero son nodos de Skyframe, entradas del action cache, y entradas de runfiles manifests).
- **Análisis:** cada `File` declarado y cada `ctx.actions.symlink` cuesta memoria de análisis por target.
- **`sys.path` runtime:** first-party imports agregan una entrada por import root; repos con muchos `imports = [...]` degradan cada import fallido (stat por entrada).

---

## 4. El cambio propuesto

### 4.1 Superficie de configuración y gating

```starlark
# py/BUILD.bazel
bool_flag(name = "experimental_indexed_imports", build_setting_default = False)
```

- Atributo nuevo `indexed_imports` (`attr.bool`, **default `True`**) en los attrs del venv, agregado a `_VENV_ONLY_ATTRS` para que fluya desde el macro `py_binary`/`py_test`.
- Gating en `_assemble_venv_target` (`py_venv.bzl`):

```starlark
if (ctx.attr.indexed_imports and
    hasattr(ctx.attr, "_indexed_imports") and
    ctx.attr._indexed_imports[BuildSettingInfo].value):
    indexed_runfiles = _py_library.make_merged_runfiles(...)
```

El label `_indexed_imports` (más `_import_index_shim` y `_import_index_generator`) se agrega **solo a `_py_venv_lib`** — la regla del venv privado. La regla pública `_py_venv` no lo tiene, así que `hasattr` corta y el venv público es físico incondicionalmente. El diseño del gate es triple: flag global AND atributo por-target AND variante de regla.

`indexed_runfiles` son los runfiles mergeados de srcs + resolución de virtuals: el universo de paths first-party que el índice debe cubrir.

### 4.2 Flujo de datos nuevo

```
resolve_wheel_collisions(ctx, wheels, wheel_by_site_packages, known_layout_site_pkgs)
        │  (out-params nuevos)
        ▼
_indexed_projection_plan(...)          ← decide qué proyecciones se virtualizan
        │
        ├── retained_projections ──► loop de symlinks físicos (igual que baseline)
        └── wheel_projections   ──► records "W" para la acción
        
Args (param file "records"):
  R  imports_depset          C  fully covered sps        H  known-layout-con-skips sps
  S/T  files de runfiles     L/Q  symlinks               A/B  root_symlinks
  W  proyecciones virtualizadas de wheels

        │  acción PyImportIndex (intérprete exec-config)
        ▼
import_index.py::generate()
        │
        ├── .aspect_rules_py_import_index   (TSV: I / D / R / P / N)
        ├── <venv_stem>.pth                 (PATH line, import shim, roots K, addsitedir X)
        └── _aspect_rules_py_import_index.py (copia byte a byte del shim)

runtime:  site.py procesa el .pth → import del shim → install_import_index()
          → _IndexedImportFinder insertado ANTES de PathFinder en sys.meta_path
```

### 4.3 La acción `PyImportIndex` y su propiedad clave

```starlark
ctx.actions.run(
    mnemonic = "PyImportIndex",
    executable = exec_runtime.interpreter,
    arguments = [arguments, records],
    inputs = depset(
        direct = [generator, shim],
        transitive = [exec_runtime.files],
    ),
    outputs = [index_file, site_packages_pth_file, import_index_shim],
    execution_requirements = {"supports-path-mapping": "1"},
)
```

**Propiedad clave:** los records se construyen con `Args.add_all(...)` sobre depsets de `File`s (`imports_depset`, `indexed_runfiles.files/symlinks/root_symlinks`, `wheel_projections`) usando `map_each`, pero **esos Files no son inputs de la acción**. La acción consume paths declarados, no contenidos. Consecuencias:

1. La acción **no espera** a que los wheels ni las fuentes se construyan — corre en cuanto el intérprete exec está disponible. No alarga el critical path.
2. Su action key depende solo del *conjunto de paths*, que es información de análisis. Es estable ante cambios de contenido de fuentes.
3. Reemplaza también el `ctx.actions.write` del `.pth` (la acción emite el `.pth`).

**Costo nuevo:** un spawn de intérprete Python por venv indexado (vs. `ctx.actions.write` + N symlink actions locales). El autor mide ~127 ms para ~37k records. Bajo RBE, es una acción remota más con path mapping.

Nota: si el exec-tools toolchain no está registrado, el modo indexado hace `fail` explícito (mismo patrón que `PySiteMerge`).

### 4.4 Formato de records de entrada (venv.bzl → import_index.py)

TSV, un record por línea, `<kind>\t<valor>`:

| Kind | Fuente | Semántica |
|---|---|---|
| `R` | `imports_depset` | Import root, en orden de precedencia del `.pth` baseline. |
| `C` | `fully_covered_site_pkgs` | `site-packages` de wheel totalmente cubierto (su root desaparece del path). |
| `H` | `known_layout_site_pkgs` (out-param, **semántica nueva**: sps con top-levels que tuvieron skips y no quedaron cubiertos) | Root de wheel que debe **retenerse físico** en el `.pth` (kind `K`), no `addsitedir`. |
| `S` / `T` | `indexed_runfiles.files` (`map_each = _source_record`) | Archivo fuente / tree artifact (directorio opaco). Archivos no-Python colapsan a su directorio (`dir/` con slash final). Paths externos (`../`) se descartan. |
| `L` / `Q` | `indexed_runfiles.symlinks` | Symlink de runfiles a archivo / a directorio (paths workspace-relative). |
| `A` / `B` | `indexed_runfiles.root_symlinks` | Root symlink a archivo / a directorio (paths runfiles-root-relative; solo se aceptan bajo el workspace). |
| `W` | `wheel_projections` (lo virtualizado por `_indexed_projection_plan`) | `entry \t site_packages`: una proyección de wheel que ya no será symlink. |

### 4.5 El generador: `import_index.py::generate()`

Algoritmo (195 líneas, puro, testeado por unittest):

1. **Wheels:** cada `W` se reduce a su nombre importable de primer nivel (strip de `.py/.pyc`, primer segmento antes de `.` para `.so/.pyd`) y acumula `nombre → {roots}` (records `I`). Entradas `*.dist-info`/`*.egg-info` de raíz van a records `D`.
2. **Clasificación de import roots** (en orden del depset, preservado):
   - root cubierto (`C`) → desaparece;
   - root `…site-packages` no cubierto → kind `X` (línea `addsitedir` en el `.pth`, `K` en el índice) — el equivalente del fallback de layout desconocido del baseline;
   - root bajo un tree artifact opaco, o fuera del workspace, o con `site-packages` en sus segmentos → kind `K` (retenido físico);
   - root first-party del workspace → kind `F` (candidato virtual), insertado en un **trie** de segmentos con su posición.
3. **Claims:** cada path fuente se camina por el trie; en cada root terminal atravesado, el siguiente segmento produce un nombre importable de top-level → `claims[nombre] ∋ posición` (records `P`).
4. **Namespaces first-party:** un nombre reclamado por ≥2 roots genera claims por subpaquete descendiendo el path (records `N`), cortando donde aparece un `__init__.py` (paquete regular: de ahí para abajo un solo dueño resuelve) o un árbol opaco.
5. **Degradación segura:** un root `F` que ningún claim reclamó se degrada a `K` — conserva su entrada física en `sys.path`. Nada se pierde silenciosamente.
6. **`.pth` de salida:** línea de `$PATH` (idéntica al baseline), `import _aspect_rules_py_import_index`, los paths `K` planos, y las líneas `addsitedir` `X` (mismo truco `known_paths`).

### 4.6 Formato del índice de salida (`.aspect_rules_py_import_index`)

| Kind | Forma | Semántica runtime |
|---|---|---|
| `I` | `I \t nombre \t root…` | Import top-level de wheel → roots dueños (venv-relative, se insertan justo tras `site-packages` en el path de búsqueda efímero). |
| `D` | `D \t dist-info-dir \t root` | Metadata de distribución virtualizada, para los bridges de `importlib.metadata` / `pkg_resources`. |
| `R` | `R \t K\|F \t root` | Orden original completo de import roots. `K` = está en `sys.path` físico; `F` = virtual. Las posiciones son los índices que usan `P`/`N`. |
| `P` | `P \t nombre \t pos…` | Top-level first-party → posiciones de roots que lo reclaman. |
| `N` | `N \t a.b.c \t pos…` | Hijo de namespace first-party repartido entre roots. |

### 4.7 El shim runtime: `_IndexedImportFinder`

432 líneas, sin dependencias, instalado **antes** de `PathFinder` en `sys.meta_path`. Mecánica:

**Resolución de un top-level (`find_spec(fullname, path=None)`):**
1. Descarta dotted names y stdlib (`sys.stdlib_module_names`), salvo los módulos puente.
2. Copia `sys.path`, y reconstruye la precedencia original: los roots virtuales `F` que reclaman el nombre se insertan en la posición que tendrían relativa a los roots `K` retenidos aún vivos en `sys.path` (soporta que el usuario haya mutado `sys.path`); los roots de wheels (`I`) se insertan inmediatamente después del `site-packages` del venv.
3. Delegación total: `path_finder.find_spec(fullname, search_paths, target)`. El finder **no carga nada** — el loader, los specs, los namespace paths son los de CPython.

**Namespaces first-party (`find_spec` con `path` no-None):**
- Solo actúa si el entorno está "prístino": `sys.path_hooks` sin cambios, él mismo inmediatamente antes de `PathFinder` en `meta_path`, y el `__path__` del padre es el `_NamespacePath` original. Cualquier desviación → `return None` (cede a la maquinaria estándar).
- Poda porciones del `__path__` del padre que pertenecen a roots que *no* reclaman el hijo — evita stats inútiles — respetando importers custom (solo poda entradas cuyo importer es `FileFinder`).
- Engancha `spec.submodule_search_locations._path_finder` para que los refrescos de namespace pasen por él.

**Puentes de ecosistema** (interceptando `exec_module` del módulo al importarse):
- `pkgutil`: parchea `extend_path` para que los namespaces first-party virtuales sigan uniéndose.
- `pkg_resources`: registra cada distribución `D` en `working_set` con `PathMetadata` real (y ubica `location` en el root del wheel post-activación).
- `importlib.metadata` / backport `importlib_metadata`: envuelve `find_distributions` para inyectar `PathDistribution`s de los records `D` exactamente en la posición de `site-packages` dentro del contexto de búsqueda, con cache de lecturas de `METADATA`/`entry_points.txt`/`PKG-INFO` (los runfiles son inmutables) y `weakref` para no crear ciclos.
- `iter_modules(prefix)` en el finder: `pkgutil.iter_modules()` enumera también lo indexado.

**Idempotencia:** el shim marca el finder con el path del índice y no se reinstala (relevante para `multiprocessing` spawn y subprocesos que re-ejecutan `site`).

### 4.8 `_indexed_projection_plan`: qué queda físico

La función (en `venv.bzl`) divide `top_level_to_site_pkgs` en `retained_projections` (siguen siendo symlinks) y `wheel_projections` (van al índice). Un wheel **retiene** su proyección física cuando:

1. **No está fully covered** — su fallback sigue vivo, virtualizarlo cambiaría precedencias.
2. **Tiene `.pth` ejecutables en su raíz** (`projected_pth_sites`) — un `.pth` con código solo corre si el archivo está físicamente en el `site-packages` del venv.
3. **Colisión de spelling**: dos proyecciones distintas resuelven al mismo nombre importable (`import_spellings[name] = None`) — el índice no puede representar la precedencia fina, se conserva el layout físico.
4. Sus entradas no son nombres importables ni metadata (data-like) — permanecen como symlinks.

Además, wheels con merges (`PySiteMerge`), proyecciones nativas y data files PEP 427 **no cambian en absoluto**: el plan solo virtualiza lo que era un symlink 1:1 seguro.

Detalle frágil: el parámetro `ordered_metadata = True` habilita un `break` que asume que las entradas de metadata (`*.dist-info`) aparecen **al final** del dict `projections` — cierto hoy porque `_resolve_metadata_collisions` es el último pase que escribe `top_level_to_site_pkgs`, pero es un acoplamiento por orden de inserción entre dos archivos.

### 4.9 Cambios en `virtuals_resolvers.bzl`

Además del refactor mecánico (dict-como-set → builtin `set` de Starlark, fast-path para nombres sin duplicados vía `tl_duplicates`/`metadata_duplicates`), hay dos cambios de fondo:

1. **Out-params nuevos:** `resolve_wheel_collisions(ctx, wheels, wheel_by_sp = None, known_layout_site_pkgs = None)`. El segundo se llena con "sps con skips que no quedaron fully covered" — nótese que **redefine el significado** del nombre `known_layout_site_pkgs`: en baseline era "wheels con `top_levels` declarados"; ahora es un subconjunto distinto que alimenta los records `H` y la clausura `_format_imp` del camino físico.
2. **Eliminación de `covered_per_wheel`:** `_compute_fully_covered` pasa de "cada top-level es dueño o está covered, y ninguno skipped" a simplemente "ningún top-level skipped". La equivalencia descansa en un invariante implícito del resolver: *todo claimant termina siendo dueño, skipped, o covered* — es decir, "no skipped ⟹ dueño o covered". Leyendo los pases (`_resolve_directory_collision`, `_resolve_native_span`, `_resolve_pure_namespace`, last-wins) el invariante parece sostenerse, pero era exactamente lo que el tracking explícito garantizaba por construcción. **Esto necesita o una prueba en el PR o un test de equivalencia** — un futuro pase que olvide llamar `_skip` para un perdedor haría que su wheel se declare fully covered (y por lo tanto virtualizable) incorrectamente, que es la clase de bug silencioso de runtime más cara de diagnosticar.

### 4.10 Cambios en `uv/`

Motivación: en modo indexado, un wheel fully covered ya no está en `sys.path`, así que la fidelidad del layout derivado importa más, y el costo del re-derive en análisis se paga por cada consumidor.

- **`exclude_glob` baja al repository rule.** La extension (`defs.bzl`) calcula, por wheel compartido, si *todos* los consumidores declaran las mismas exclusiones. Si sí → `whl_dist` filtra `record_segments` **antes** de `derive_layout` en el repo y no carga `record_paths`. Si hay conflicto → se comporta como baseline (RECORD completo, re-derive por consumidor en `whl_install`).
- **Contrato de `record_paths` cambia** (doc del provider `PyWheelMetadataInfo`): ahora se emiten cuando hay consumidores en conflicto o cuando el filtrado vació el layout (para mantener distinguibles los prebuilt de los source-built).
- **`parse_record_path`** gana un fast-path para líneas sin comillas (la mayoría absoluta de RECORDs).
- **`search.py`** (resolución de entrypoints de `py_entrypoint_binary`): si detecta el shim en `sys.modules`, resuelve el console script vía `importlib.metadata.entry_points()` (que el shim ya puentea) antes de escanear `sys.path` — necesario porque los `dist-info` virtualizados no están en el filesystem del venv.
- **`sdist_build`** fuerza `indexed_imports = False` en el `py_binary` del build helper PEP 517: construir un sdist requiere que el build backend vea un `site-packages` físico.

**Efecto lateral a evaluar:** `exclude_glob` como atributo de `whl_dist` entra al fingerprint del repository rule → cambiar exclusiones invalida y re-fetchea el repo del wheel (baseline: solo re-análisis). Y la detección de "consumidores en conflicto" ocurre en la extension, o sea a nivel de resolución del module extension, no por target.

---

## 5. Matriz de compatibilidad

| Consumidor / patrón | Venv privado indexado | Mecanismo |
|---|---|---|
| `import x` / `from x import y` | ✅ | Finder → PathFinder con path efímero |
| Namespace packages PEP 420 (wheels y first-party) | ✅ | Records `I` multi-root / `N` + poda de `__path__` |
| `pkgutil.extend_path` (namespaces legacy) | ✅ | Patch de `extend_path` |
| `pkgutil.iter_modules` | ✅ | `iter_modules` en el finder |
| `importlib.metadata` (`version()`, `entry_points()`, …) | ✅ | Wrap de `find_distributions` + records `D` |
| Backport `importlib_metadata` | ✅ | Wrap de `MetadataPathFinder` |
| `pkg_resources` (`working_set`, `iter_entry_points`) | ✅ | Registro en `working_set` |
| Plugins de pytest vía entry points | ✅ (por transitividad) | `importlib.metadata` bridge |
| Console scripts (`subprocess.run("black")`) | ✅ | `$PATH` line + wrappers `bin/` intactos |
| `.pth` ejecutables de wheels | ✅ | El wheel retiene proyección física |
| Wheels de layout desconocido (source-built) | ✅ | Kind `X` → `addsitedir`, igual que baseline |
| Extensiones nativas, merges, data files | ✅ | Fuera del alcance del plan (sin cambios) |
| Typecheckers / IDEs (mypy, pyright, jump-to-def) | ❌ por diseño | Usar venv público (`expose_venv`) — siempre físico |
| Copiar `sys.path` a otro intérprete / herramientas que escanean el filesystem | ❌ | `indexed_imports = False` por target |
| Build de sdists (PEP 517) | ❌ | Opt-out forzado en `sdist_build` |

---

## 6. Análisis

### 6.1 Modelo de rendimiento

Qué se ahorra, por venv privado indexado con `W` proyecciones virtualizadas:

| Concepto | Baseline | Indexado |
|---|---|---|
| Acciones symlink de site-packages | ~`W` + retenidas | solo retenidas |
| Acción de escritura del `.pth` | 1 (`ctx.actions.write`) | 0 (lo emite la acción de índice) |
| Acción nueva | — | 1 `PyImportIndex` (spawn de Python) |
| Outputs declarados | ~`W` Files/symlinks | 3 Files (índice, `.pth`, shim) |
| Entradas de runfiles manifest | ~`W` | 3 |
| `sys.path` runtime | roots first-party + fallbacks | roots retenidos + fallbacks (más corto) |

El ahorro domina porque `W` se multiplica por el número de targets. El costo marginal nuevo es un proceso Python por venv en ejecución (no en análisis), amortizado por el action cache: como la key depende de paths y no de contenidos, ediciones de código no la invalidan — solo cambios de estructura de dependencias.

Adicional no obvio: el arranque del intérprete mejora en repos con `sys.path` largos (menos entradas → menos stats por import fallido), y el costo de leer el índice + instalar el finder es un archivo TSV secuencial.

**Verificación recomendada antes del merge:** reproducir las métricas en un repo público de tamaño medio (p. ej. los e2e de rules_py con `--profile` y `bazel analyze-profile`), y medir el delta de arranque del intérprete con `python -X importtime` en un test con ~100 wheels.

### 6.2 Registro de riesgos

| # | Riesgo | Severidad | Detalle / mitigación |
|---|---|---|---|
| R1 | **Dependencia de internals de CPython** | Alta | `_NamespacePath._path_finder` (privado, sin contrato de estabilidad), identificación de `PathFinder` por `__name__`, de `FileFinder` por `type(...).__name__`, wrap de `spec.loader.exec_module`, override por-instancia de `Distribution.read_text`. Cada minor de CPython es un evento de riesgo. Mitigación: matriz de tests de ejecución por versión soportada; los guards defensivos del shim (ceder a la maquinaria estándar ante cualquier desviación) están bien pensados, pero solo cubren los casos previstos. |
| R2 | **Shim de 432 líneas sin tests de ejecución en el diff** | Alta | El PR agrega unittest del *generador* y analysistests del *layout*, pero ningún test corre el finder contra paquetes reales (namespaces `google.cloud`-style, `pkg_resources`, plugins por entry points, `multiprocessing`). El body dice "54 focused Bazel tests"; el diff muestra 3 métodos de unittest + 3 analysistests. Bloqueante: exigir e2e de runtime. |
| R3 | **Cambio semántico en `_compute_fully_covered`** | Media | Ver §4.9. La equivalencia "no skipped ⟹ covered" es plausible pero no está probada ni testeada, y `fully_covered` ahora decide *elegibilidad de virtualización*, amplificando el costo de un falso positivo. |
| R4 | **Acoplamiento por orden de inserción** (`ordered_metadata` break) | Media | `_indexed_projection_plan` asume que la metadata está al final de `top_level_to_site_pkgs`. Cierto por el orden de pases del resolver, pero es un invariante inter-archivo sin assert ni test. |
| R5 | **Builtin `set` de Starlark** | Media/Baja | Requiere Bazel ≥ 8.1. El repo está en 8.6.0, pero hay que confirmar la versión mínima que rules_py declara soportar a consumidores (los `.bzl` se cargan en el Bazel del consumidor). |
| R6 | **Reubicación de `exclude_glob` al repo rule** | Media | Cambia fingerprints de repos externos (re-fetch al cambiar exclusiones), y la unificación "todos los consumidores coinciden" se decide en la module extension. Es una optimización ortogonal a indexed imports que viaja en el mismo PR. |
| R7 | **Out-params mutables en `resolve_wheel_collisions`** | Baja | Funciona, pero el contrato de la función pública ahora incluye efectos sobre argumentos. Preferible retornar los dos valores. |
| R8 | **Redefinición silenciosa de `known_layout_site_pkgs`** | Media | El mismo nombre significa dos cosas distintas antes y después del PR, y alimenta tanto `_format_imp` (camino físico) como los records `H`. Alto potencial de confusión en mantenimiento futuro; renombrar. |
| R9 | **Interacción con mutaciones de `sys.meta_path`/`path_hooks` por terceros** | Baja/Media | El shim cede correctamente (namespace pruning se autodesactiva), pero un finder de terceros insertado *antes* del shim que resuelva nombres indexados cambia precedencias vs. el layout físico. Documentar. |

### 6.3 Preguntas para el autor (review)

1. ¿Contra qué matriz de versiones de CPython corrieron el shim (3.9–3.13, freethreaded)? `_NamespacePath._path_finder` y `sys.stdlib_module_names` (3.10+) acotan el piso — ¿cuál es el mínimo declarado?
2. ¿Pueden aportar los e2e de runtime que respaldan la lista de compatibilidad del §5? En particular: namespace de dos wheels + first-party sobre el mismo top-level, `pkg_resources.iter_entry_points`, plugin de pytest por entry point, `multiprocessing.spawn`.
3. ¿Hay una prueba (o test parametrizado) de la equivalencia del nuevo `_compute_fully_covered`?
4. ¿Por qué el refactor de `virtuals_resolvers` y la reubicación de `exclude_glob` viajan en este PR? ¿Cuáles son prerequisitos duros del feature y cuáles son mejoras separables?
5. El `break` de `ordered_metadata`: ¿aceptan un assert estructural o un test que fije el invariante de orden?
6. ¿Cómo interactúa el índice con `py_pex_binary` y las reglas de imagen (que consumen `install_tree` como package leaf)? A primera vista no cambia, pero el `.pth` del venv empaquetado ahora importa el shim.

### 6.4 Alternativas (contexto, no propuesta)

- **Venv físico compartido entre targets** (un solo `site-packages` por grupo de deps): elimina la multiplicación pero rompe el aislamiento por-target y la precedencia postorder por binario.
- **Tree artifact para el site-packages**: colapsa outputs pero reintroduce los problemas de materialización remota que el header de `venv.bzl` cita como razón del diseño actual.
- **Solo `.pth` (todo a `sys.path`)**: es el fallback actual; escala mal en arranque (O(N) stats por import) y expone metadata duplicada.

El enfoque del PR es la misma familia de solución que los import hooks de otros build systems a gran escala (el finder estático sobre un manifiesto): ataca el costo donde está (multiplicación de acciones) sin tocar el aislamiento ni la precedencia. La dirección es correcta; el riesgo está concentrado en el shim runtime y en los cambios semánticos colaterales.

---

## 7. Recomendación

1. **La feature, detrás del flag experimental y con el gate triple, es mergeable en dirección** — el diseño de degradación (todo caso dudoso retiene comportamiento físico) es sólido y el default no cambia nada para nadie.
2. **Bloqueantes antes del merge:**
   - Tests de ejecución del shim (matriz CPython × los casos del §5), no solo del generador.
   - Prueba o test de equivalencia del cambio en `fully_covered` (R3).
   - Assert o test del invariante de orden de metadata (R4).
   - Renombrar `known_layout_site_pkgs` en su nueva acepción (R8).
3. **Pedir separación** (o justificación de acoplamiento) de: el refactor a `set`/fast-paths de `virtuals_resolvers` y la reubicación de `exclude_glob` en `uv/`. Ambos son valiosos pero revisables de forma independiente, y cada uno tiene su propio blast radius (R5, R6).
4. **Documentar** en el sitio de docs: la matriz de compatibilidad, el opt-out por target, y la garantía "venv público = siempre físico".
