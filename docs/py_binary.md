<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Implementation for the py_binary and py_test rules.

<a id="py_binary"></a>

## py_binary

<pre>
py_binary(<a href="#py_binary-name">name</a>, <a href="#py_binary-data">data</a>, <a href="#py_binary-deps">deps</a>, <a href="#py_binary-env">env</a>, <a href="#py_binary-imports">imports</a>, <a href="#py_binary-main">main</a>, <a href="#py_binary-srcs">srcs</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_binary-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_binary-data"></a>data |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_binary-deps"></a>deps |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_binary-env"></a>env |  -   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional | <code>{}</code> |
| <a id="py_binary-imports"></a>imports |  -   | List of strings | optional | <code>[]</code> |
| <a id="py_binary-main"></a>main |  -   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="py_binary-srcs"></a>srcs |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |


<a id="py_test"></a>

## py_test

<pre>
py_test(<a href="#py_test-name">name</a>, <a href="#py_test-data">data</a>, <a href="#py_test-deps">deps</a>, <a href="#py_test-env">env</a>, <a href="#py_test-imports">imports</a>, <a href="#py_test-main">main</a>, <a href="#py_test-srcs">srcs</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="py_test-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="py_test-data"></a>data |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_test-deps"></a>deps |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |
| <a id="py_test-env"></a>env |  -   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional | <code>{}</code> |
| <a id="py_test-imports"></a>imports |  -   | List of strings | optional | <code>[]</code> |
| <a id="py_test-main"></a>main |  -   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |
| <a id="py_test-srcs"></a>srcs |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional | <code>[]</code> |


<a id="py_base.implementation"></a>

## py_base.implementation

<pre>
py_base.implementation(<a href="#py_base.implementation-ctx">ctx</a>)
</pre>



**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="py_base.implementation-ctx"></a>ctx |  <p align="center"> - </p>   |  none |


