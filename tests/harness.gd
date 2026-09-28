class_name TestHarness
extends RefCounted
##
## 极简 headless 断言器。所有断言走 ck()/eq()，失败收集进 _fails，
## 最后由测试脚本汇总打印 PASS/FAIL 并返回退出码。
##
## 从《物候》工程 tests/harness.gd 迁移而来，去掉了依赖物候逻辑层的
## new_game() / diff_snapshots() 两个静态方法（本项目不涉及）。
##

var _pass: int = 0
var _fails: Array[String] = []
var _suite: String = ""


func suite(name: String) -> void:
	_suite = name
	print("")
	print("── 用例组：", name)


func ck(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("   [ck] PASS  ", msg)
	else:
		_fails.append("[%s] %s" % [_suite, msg])
		print("   [ck] FAIL  ", msg)


func eq(a: Variant, b: Variant, msg: String) -> void:
	ck(a == b, "%s  (实际=%s / 期望=%s)" % [msg, str(a), str(b)])


func pass_count() -> int:
	return _pass


func fail_count() -> int:
	return _fails.size()


func failures() -> Array[String]:
	return _fails
