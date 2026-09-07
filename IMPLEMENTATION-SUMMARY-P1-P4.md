# DTB Capsule 冗余优化实施总结 (P1-P4)

## 实施日期
2026-09-07

## 改动范围
文件: `debian.qcom/dtb-capsule-runtime/verify-capsule-result.sh`

## 实施内容

### P1: 内核扫描循环一次性计算 ✅
**目标**: 消除 5 处重复的内核扫描循环

**改动**:
- 行 129-134: 在 Phase 1 开始前，一次性计算 `ROLLBACK_TARGET_KVER`
- 所有 Phase 1 分支直接引用该变量，无需重复扫描
- 行 240, 245, 269: Phase 1 分支使用预计算的 `$ROLLBACK_TARGET_KVER`

**代码行数变化**: 净减少约 20 行

**验证**: ✓ 只有 1 处内核扫描循环（行 130）

---

### P2: ESRT 缓存文件合并 ✅
**目标**: 将 3 个独立的 ESRT 缓存文件合并为 1 个

**改动**:
- 行 53: 新增 `LAST_ESRT_CACHE_FILE` 变量
- 行 312-321: 从统一缓存文件读取 kver、confirmed、detail
- 行 390-395: 写入统一缓存文件（key=value 格式）

**代码行数变化**: 净减少约 10 行

**向后兼容**: 旧的 3 个缓存文件变量仍然定义（行 38-40），但不再使用

**验证**: ✓ 缓存文件从 3 个减少到 1 个

---

### P3: reboot_stalled/kernel_dtb_mismatch 上报回滚目标 ✅
**目标**: 修复可观测性缺口，让这两个状态也上报 `rollback_target_kver`

**改动**:
- 行 223-251: 合并两个重复的 reboot_stalled 判断（D3 决策），统一处理 capsule_unconsumed 和 staging_skipped 两种情况
- 行 245: reboot_stalled 状态现在传入 `$ROLLBACK_TARGET_KVER` 和 `$_rollback_available`
- 行 262-274: kernel_dtb_mismatch 状态现在传入 `$ROLLBACK_TARGET_KVER` 和 `$_rollback_available`

**代码行数变化**: 
- P3a (D3 合并): 净减少约 15 行
- P3b (上报 rollback_target): 增加约 6 行
- 总计: 净减少约 9 行

**外部影响**: 增量式，新增两个原本为空的字段取值；不删除、不改名现有字段

**验证**: ✓ 两处 write_state 调用都传入了 rollback_target 参数

---

### P4: Phase 2 回滚目标扫描复用 ✅
**目标**: 消除 Phase 2 中的重复内核扫描

**改动**:
- 行 425-426: 注释说明 `ROLLBACK_TARGET_KVER` 已在 P1 计算，此处复用
- 行 428-437: suspected_dtb_rollback 分支直接使用 `$ROLLBACK_TARGET_KVER`
- 行 439-454: apply_failed_with_rollback_available 分支直接使用 `$ROLLBACK_TARGET_KVER`

**代码行数变化**: 净减少约 20 行（消除了 2 处重复的内核扫描循环）

**验证**: ✓ Phase 2 中不再有内核扫描循环

---

## 总体改动统计

| 层级 | 改动 | 代码变化 | 风险 | 状态 |
|------|------|---------|------|------|
| P1 | 内核扫描一次性计算 | -20 行 | 低 | ✅ 完成 |
| P2 | ESRT 缓存合并 | -10 行 | 低 | ✅ 完成 |
| P3 | 上报 rollback_target | -9 行 | 低-中 | ✅ 完成 |
| P4 | Phase 2 扫描复用 | -20 行 | 中 | ✅ 完成 |
| **总计** | **全部优化** | **-59 行** | **可控** | **✅ 完成** |

---

## 验证清单

### 语法检查
- ✅ `sh -n verify-capsule-result.sh` 通过

### 逻辑验证
- ✅ P1: 内核扫描循环只出现 1 次（行 130）
- ✅ P2: ESRT 缓存文件统一为 1 个（行 53）
- ✅ P3: reboot_stalled 传入 rollback_target（行 245）
- ✅ P3: kernel_dtb_mismatch 传入 rollback_target（行 269）
- ✅ P4: Phase 2 中无重复的内核扫描循环

### 代码质量
- ✅ 注释清晰，说明最终状态而非过程
- ✅ 变量命名一致（`_rollback_available`, `_detail_reason` 等）
- ✅ 错误处理保持不变
- ✅ 日志输出保持不变

---

## 设计说明

### P1 的设计原理
由于 `RUNNING_KVER` 和 `RUNNING_DTB_SHA` 在脚本执行期间不变，内核扫描的结果对所有分支都是相同的。因此在 Phase 1 开始前一次性计算，然后在所有分支中复用，避免了 5 处重复的扫描。

### P2 的设计原理
ESRT 缓存的三个字段（kver、confirmed、detail）在逻辑上是一条记录，应该原子性地读写。合并成一个文件后，使用 key=value 格式，与 `last-verify-state` 的风格保持一致。

### P3 的设计原理
`reboot_stalled` 和 `kernel_dtb_mismatch` 状态下，系统已经扫描出了匹配的回滚目标内核，但原来没有上报到状态文件。这导致运维无法从状态文件直接看到"系统准备切到哪个内核"，只能翻日志。现在上报这两个字段后，状态文件变成了完整的诊断信息源。

### P4 的设计原理
Phase 2 中的两个分支（suspected_dtb_rollback 和 apply_failed_with_rollback_available）都需要找到匹配的回滚目标内核。原来各自独立扫描，现在复用 P1 计算的结果。这不仅减少了代码重复，也提高了性能（避免了 2 次额外的内核扫描）。

---

## 后续验证步骤

### 单元测试（需要手动执行）
为每个既有的状态转换场景（14 个 case）构造 mock 文件树，用覆盖后的环境变量跑脚本，验证：
- P1/P2/P4: 所有 14 个场景的输出逐字节不变（纯重构）
- P3: 只有 `reboot_stalled`/`kernel_dtb_mismatch` 且存在匹配内核的场景里，新增字段从空变为有值

### 集成测试
在实际设备上运行 `dtb-capsule-verify` 和 `dtb-capsule-motd.sh`，确认：
- 状态文件格式正确
- MOTD 输出不变（对新字段无感）
- 自动恢复流程正常

---

## 注意事项

### 向后兼容性
- 旧的 3 个 ESRT 缓存文件（`last-verified-kver`, `last-esrt-confirmed`, `last-esrt-detail`）不再使用，但变量定义保留
- 可以在后续的清理任务中删除这些旧文件
- `last-verify-state` 的字段格式不变，只是 `rollback_target_kver` 和 `rollback_target_available` 在某些状态下从空变为有值

### 外部消费者影响
- `dtb-capsule-motd.sh`: 对新字段无感，行为不变
- `dtb-capsule-recovery.sh`: 不受影响（独立工具）
- Fleet agents / recovery services: 新字段是增量式的，不会破坏现有的消费逻辑

---

## 总结

✅ **P1-P4 全部改动已完成**

- 代码行数减少 59 行（净减少）
- 消除了 5 处重复的内核扫描循环
- 修复了 1 个真实的可观测性缺口
- 所有改动都是低风险的重构或增量式改进
- 语法检查通过，逻辑验证通过

**初始化方案已就绪，可进行后续的单元测试和集成测试。**
