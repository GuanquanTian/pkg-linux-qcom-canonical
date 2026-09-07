# DTB Capsule 流程图更新 (v3) - 与 P1-P4 代码优化同步

## 更新日期
2026-09-07

## 更新原因
代码实现了 P1-P4 优化后，流程图需要同步更新以反映最新的实现细节。

## 具体改动

### 1. 自动恢复触发点表格 (行 397-414)
**改动内容**:
- 第 4 项从 "apply_failed + matching kernel found" 改为 "apply_failed_with_rollback_available + matching kernel found"
- 更新所有代码行号以反映 P1-P4 优化后的新行号

**原因**: 
- 代码中 apply_failed 分为两种情况：
  - 有匹配内核 → apply_failed_with_rollback_available（触发自动恢复）
  - 无匹配内核 → apply_failed（不触发自动恢复）
- 流程图之前的描述不够准确

**更新前**:
```
4 | apply_failed + matching kernel found | Call run_auto_recovery() | Line 448
```

**更新后**:
```
4 | apply_failed_with_rollback_available + matching kernel found | Call run_auto_recovery() | Line 448
```

**行号更新**:
- reboot_stalled: Line 224, 241 → Line 240, 245
- kernel_dtb_mismatch: Line 265 → Line 268
- suspected_dtb_rollback: Line 427 → Line 434
- apply_failed_with_rollback_available: Line 448 → Line 448 (不变)

---

### 2. Phase 2 流程图增强 (行 779-888)
**改动内容**:
- 在 "ESRT_CONFIRMED == 0?" 的判断后添加子决策节点
- 区分 "有 ROLLBACK_TARGET_KVER" 和 "无 ROLLBACK_TARGET_KVER" 两种情况
- 分别导向 apply_failed_with_rollback_available 和 apply_failed

**原因**:
- 代码中 ESRT_CONFIRMED == 0 时的处理逻辑有两个分支
- 流程图之前只显示了一个分支（apply_failed），缺少了 apply_failed_with_rollback_available 的处理

**改动前**:
```
ESRT_CONFIRMED == 0? 
  ├─ Yes → apply_failed
  └─ No → (continue to content_mismatch_localized)
```

**改动后**:
```
ESRT_CONFIRMED == 0?
  ├─ Yes
  │   ├─ ROLLBACK_TARGET_KVER found?
  │   │   ├─ Yes → apply_failed_with_rollback_available
  │   │   └─ No → apply_failed
  │   └─ (end)
  └─ No → (continue to content_mismatch_localized)
```

**SVG 调整**:
- 增加了一个新的决策菱形（ROLLBACK_TARGET_KVER found?）
- 调整了后续元素的位置
- 更新 SVG viewBox 从 "0 0 1200 1260" 改为 "0 0 1400 1350"

---

### 3. State Output File 说明增强 (行 431-446)
**改动内容**:
- 添加说明：rollback_target_kver 和 rollback_target_available 现在在多个状态中被填充
- 明确指出这些字段在哪些状态下会有值

**原因**:
- P3 优化后，reboot_stalled 和 kernel_dtb_mismatch 状态也会上报这两个字段
- 需要在文档中说明这一变化

**更新前**:
```
All state information is written to `/var/lib/dtb-capsule/last-verify-state` in key=value format:
```

**更新后**:
```
All state information is written to `/var/lib/dtb-capsule/last-verify-state` in key=value format. 
The `rollback_target_kver` and `rollback_target_available` fields are always emitted (even empty) 
so downstream consumers can safely test `-n "$rollback_target_kver"`. These fields are populated in 
`reboot_stalled`, `kernel_dtb_mismatch`, `suspected_dtb_rollback`, and 
`apply_failed_with_rollback_available` states when a matching kernel is found.
```

---

### 4. Key Points 说明更新 (行 942-950)
**改动内容**:
- 更新 3b (dtb_pairing_state) 的说明
- 明确区分 apply_failed_with_rollback_available 和 apply_failed 的条件

**原因**:
- 之前的说明没有明确提到 apply_failed_with_rollback_available 的存在
- 需要说明 ESRT 决策的完整逻辑

**更新前**:
```
only if no match is found does ESRT decide between `apply_failed` and `content_mismatch_localized`
```

**更新后**:
```
only if no match is found does ESRT decide between `apply_failed_with_rollback_available` 
(if a matching kernel exists) and `apply_failed` (if no match)
```

---

### 5. Kernel Rollback Recovery Flow 说明更新 (行 1061-1071)
**改动内容**:
- 更新自动恢复触发条件的说明
- 改为 "apply_failed_with_rollback_available" 而不是 "apply_failed"

**原因**:
- 与自动恢复触发点表格的改动保持一致

**更新前**:
```
verify-capsule-result.sh checks for matching kernel before invoking dtb-capsule-recovery --auto 
on kernel_dtb_mismatch, reboot_stalled, apply_failed, or suspected_dtb_rollback
```

**更新后**:
```
verify-capsule-result.sh checks for matching kernel before invoking dtb-capsule-recovery --auto 
on `kernel_dtb_mismatch`, `reboot_stalled`, `suspected_dtb_rollback`, or `apply_failed_with_rollback_available`
```

---

### 6. 文档更新日期
- 从 2026-09-03 更新为 2026-09-07

---

## 验证清单

- ✅ 自动恢复触发点表格准确反映代码实现
- ✅ Phase 2 流程图包含 apply_failed_with_rollback_available 的处理
- ✅ State Output File 说明包含 P3 改动信息
- ✅ Key Points 说明准确描述 ESRT 决策逻辑
- ✅ 所有代码行号已更新
- ✅ SVG 尺寸已调整以容纳新的决策节点
- ✅ 文档日期已更新

---

## 与代码的对应关系

### 自动恢复触发点
| 流程图 | 代码位置 | 状态 |
|--------|---------|------|
| reboot_stalled + matching kernel | 行 240, 245 | ✅ |
| kernel_dtb_mismatch + matching kernel | 行 268 | ✅ |
| suspected_dtb_rollback | 行 434 | ✅ |
| apply_failed_with_rollback_available + matching kernel | 行 448 | ✅ |

### Phase 2 决策路径
| 条件 | 代码位置 | 状态 |
|------|---------|------|
| RUNNING_DTB_MATCHES_INSTALLED_MODULES == ok | 行 295-298 | ✅ |
| ESRT_CONFIRMED == 0 + ROLLBACK_TARGET_KVER found | 行 442-449 | ✅ |
| ESRT_CONFIRMED == 0 + no ROLLBACK_TARGET_KVER | 行 450-451 | ✅ |
| ESRT_CONFIRMED == 1 + content mismatch | 行 456-503 | ✅ |

---

## 总结

✅ **流程图已与 P1-P4 代码优化同步**

- 自动恢复触发点表格更准确
- Phase 2 流程图更完整
- 所有说明都反映了最新的代码实现
- 代码行号已更新
- 文档日期已更新

**流程图现在完全准确反映了代码实现的最新状态。**
