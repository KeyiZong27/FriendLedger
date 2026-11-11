# 家庭记账

面向夫妻共同记账的 iPhone 项目，最低 iOS 17。当前界面首次启动只需设置称呼，会自动创建个人账本；
支持美元手动收支、删除记录、关闭重开后的本地恢复，同步与共享集中在右上角旁的“设置”。
收据、银行、工资和存款的内核已实现，但相应操作页面仍待完成；这还不是完整成品。

## 本地优先与加载体验

- 首次启动设置称呼后自动创建“称呼的账本”；每条新记录使用该称呼，不再每次输入，可在设置修改。
  共享前双方各自选择是否并入原有账目、退出者只带走自己添加的账目，已确认为后续设计，**尚未实现**；
  目前共享是邀请对方加入你的账本，并需要两个真实 Apple ID 验收。
  手动记账仍有分类选择；按商店名自动归类和拍照 / 相册识别在下一步实现。
- 默认只在本机：启动、创建和保存不需要联网，不请求 iCloud，也不要求先创建云端账本。
- 保存成功后才关闭输入页面；读取损坏文件或写入失败明确提示，不覆盖原文件、不清空输入。
- 主动开启“此账本 iCloud 同步”后，才将该账本上传。自己的其他同 Apple ID 设备安装 App 后，
  在设置中选择“从当前 iCloud 加载账本”；不需要共享自己的 Apple ID 密码。
- 不同 Apple ID 在设置中使用“邀请对方共享账本”，通过 Apple 的共享邀请界面发送私有读写邀请；
  对方必须接受邀请，不是输入账号后就能直接访问对方的 iCloud。
- 网络操作显示顶部转圈动画和当前阶段，连接 / 上传期间仍能创建本地账本、输入和保存记录。
  同步失败保留待上传修改；可重试，前台约每 30 秒核对一次，也支持下拉刷新。
- 每个同步账本绑定开启时的 iCloud 账号。退出或更换账号保留本地缓存，不自动上传旧账本到新账号；
  如需转移，先保存为独立本地副本，再主动选择新账号。
- 同时修改产生冲突时不覆盖双方数据。选择“保留本地副本并核对云端版本”，会先保存独立本地副本，
  再让原账本加载云端版本；可以核对后手动合并。
- 停用同步只影响本设备，保留本地和云端记录，不自动结束已有共享。
  被移出共享的成员保留缓存，但不能继续写入失效的共享账本，可另存本地副本。
- 本地缓存使用原子写入，iOS 文件启用完整文件保护，并排除系统自动云端备份。
  **只在本机的账本在卸载 App、设备丢失或损坏时可能丢失；尚未提供独立导出备份页面。**
  主动开启 iCloud 后才有对应的云端副本，不能把“保存到本地”当作异地备份。

## 已确认的方向与已实现的内核

- 日常账目统一为美元；人民币只用于展示存款目标。金额使用整数分，汇总使用 Decimal。
- [本地 OCR](Sources/FriendLedgerCore/LocalReceiptRecognizer.swift) 使用 Apple Vision，
  从照片提取英文收据文本，不调用云端 AI、地图或地理定位服务。
- [收据解析](Sources/FriendLedgerCore/ReceiptTextParser.swift) 生成必须核对的草稿：
  商家名称建议、明确标注的总额候选、商品行金额和税额。多个不同总额不能自动选择；
  缺少总额不以 SUBTOTAL、银行卡付款额或优惠金额替代。复杂版式仍需手动修正。
- [财务账本](Sources/FriendLedgerCore/HouseholdBook.swift) 确认一张收据只生成一笔支出。
  商品、税额、优惠券和小费等明细仅用于分析，不重复入账；明细与总额的差额会保留供核对，
  不强行编造缺失商品。日期、商家及最终金额须由使用者确认。
- 商家及商家类型首次手动确认保存，之后按规范化名称或明确保存的别名复用，
  不模糊猜测商家类型。历史收据保留确认时的商家类型，后续目录修改不会悄悄改写历史。
- 同一个收据草稿或相同照片指纹不能重复入账。同商家、当地同一天、同金额会提示可能重复，
  只有明确确认是不同收据后才允许继续。不同照片角度只能辅助检测，不能保证自动去重。
- 保留手动收支；未绑定商家的手动支出计入月度总额，并单独列为未归属商家支出。
- 工资手动填写税前、预扣税、其他扣款和到账金额，并核对四者关系；只有税后到账计入收入。
  预扣税不是最终税负，不提供年度报税、退税估算，也不把扣款再记一遍消费。
- 月度分析包含收支、工资、预扣税、其他工资扣款、商家及商家类型汇总，以及存款存入 / 取出。
  月份由调用方明确提供家庭所在时区，不固定按 UTC 或中国时间划分。
  收据或工资明细关联已有银行主记录时，按主记录日期归月，原始明细日期独立保留。
- 存款使用“初始夫妻合计存款 + 存入 − 取出”，与收入减支出的现金流分开。
  存款范围内账户之间的内部转账不应另记存入或取出；实际花钱仍需独立记录消费。
- 目标默认人民币 20,000,000 元。汇率没有猜测默认值：手动设置每美元兑人民币的汇率及日期后，
  才计算人民币估值和目标进度；原始美元金额不变，换算结果四舍五入到人民币分。
  不设置目标年限，不声称预测投资收益或保证达成目标。

## 银行导入与去重内核

[银行核对](Sources/FriendLedgerCore/BankImport.swift) 为银行证据建立独立队列，
`importBankTransactions(_:calendar:)` 返回并保存每次导入结果，包含重复跳过、待核对、
银行待入账、银行拒绝、已记账交易变化和错误行；导入本身不会自动增加收入或支出。

- 明确重复：同一渠道、账户、交易唯一编号，且金额、方向、日期和状态未变化，自动跳过并继续下一条。
  无唯一编号时，同一文件指纹及逻辑 CSV 行号可确认重复导入。
- 疑似重复：仅当地同日期、同金额、同方向只列为候选。不同账户、不同渠道或没有唯一编号的
  重叠流水文件，不据此自动忽略；两笔相同金额的真实消费可以分别确认入账。
- 银行待入账不计收支；同一编号由待入账转为已入账时更新证据并重新核对，
  不把最终金额（例如包含小费）当成应跳过的旧数据。
- 已关联交易若金额、状态等变化，保留原账目及原关联标识，提示人工处理，
  不静默改金额或新增第二笔。原金额恢复时可以人工重新确认关联。
- 核对动作支持关联已有收据 / 工资到账、创建新账目或明确排除。
  账户内部转账、信用卡还款等应选择排除并记录原因；存款流水仍需单独明确录入，
  不把所有银行借方 / 贷方自动当作真实消费 / 工资。
- 银行先入账、后补收据时，`confirmReceipt(...existingEntryID:)` 只附加收据明细；
  后补工资信息时 `PayrollRecord(linkedEntryID:)` 复用已有到账记录，均不重复计算。
  关联需金额、收支方向一致；日期不同可人工确认，不能自动猜测。
- 删除主账目会重新打开相关银行证据的核对状态，不删除银行导入证据。

### 本地银行文件

[CSV 导入器](Sources/FriendLedgerCore/BankCSVImporter.swift) 已支持 UTF-8、BOM、逗号分隔、
双引号转义、带引号的多行备注、CRLF 换行、规范千位分隔和括号负数。
`BankCSVMapping` 必须明确账户标识、日期格式与时区、列名，以及金额正负方向；
可选真实交易唯一编号列和 USD 币种列，也支持独立收入 / 支出两列。
账户标识应稳定且区分夫妻的不同账户，不应使用银行密码或完整账号。
唯一编号必须是真正的交易 ID，不是卡号尾号、固定备注或非唯一的参考字段。

当前 CSV 仅按**已入账流水**处理，不能直接混入 pending 交易；具体银行存在状态列、
不同日期列或特殊格式时，需要先按真实脱敏样本适配，不能靠猜测导入。
错误金额、日期、列数和币种会进入结果的错误列表，并继续处理后续有效行；
表头映射错误、文件结构错误或不支持的 PDF / Excel 会明确报错，不伪装成成功空文件。
尚未测试真实银行导出文件，也尚未实现文件选择与核对 UI。

### Apple Wallet

[Wallet 导入适配器](App/WalletTransactionImporter.swift) 按 Apple FinanceKit 官方 API 编写，
请求授权后查询用户允许的交易范围，转换成相同的核对队列输入，不读取其他 App 的推送通知。
这是手动触发的查询接口，尚无后台持续监听，不保证覆盖所有银行、账户或账期。

美国 FinanceKit 需要 iOS 17.4 或更新版本，目前支持 Apple Card、Apple Cash 和 Savings，
并有 Apple Card Family / Apple Cash Family 的使用者限制。Apple 要求申请专用 managed entitlement；
API 文档还列明组织类型 Developer 账号等条件，资格包含 Finance 类别和 App Store 分发要求。
个人自用 / 仅 TestFlight 项目不能假定可以直接获得授权：
[资格与支持范围](https://developer.apple.com/financekit/)、
[API 与权限要求](https://developer.apple.com/documentation/financekit)。

[Info.plist](Config/Info.plist) 已声明用途说明，但 `WalletImportEnabled` 默认关闭，
也没有擅自添加未获批的 entitlement。审批通过后，需在 Xcode 配置 Apple 授予的 managed capability，
更新正确签名，再启用该开关；无批准、无设备数据或用户拒绝均明确报错。
现已使用 Xcode 27.2 完成 iOS 模拟器构建，并确认 SDK 可以导入 FinanceKit，
因此 **iOS FinanceKit 分支已通过编译，但没有读取真实 Wallet 交易**。
仍需签名审批、用户授权和真机验收，不能把编译通过当成账户接入成功。

## 持久化与共享接口

内核提供 `HouseholdBook.encoded()` / `decode(_:)`，保存全部商家、收据、工资、存款、银行证据和导入报告，
带版本与 USD 币种检查；解码后验证记录关联及金额，不接受损坏快照。
原始照片和完整 OCR 文本不进入已确认账本快照，只保留核对后的字段及照片指纹。
银行原始文件也不保存到快照，只保留选定的结构化字段；旧快照缺少银行队列时按空队列迁移，
不会重建或更改原收据、工资和存款金额。

[LocalLedgerCache](Sources/FriendLedgerCore/LocalLedgerCache.swift) 保存本地账本、修改版本、
待上传状态、账号绑定和云端基线；[LedgerStore](App/LedgerStore.swift) 已把手动收支界面接入美元内核。
上传旧版本期间新增的本地记录不会因收到上传确认而丢失。

[CloudLedgerService](App/CloudLedgerService.swift) 批量读取私有 / 共享记录区的账本和财务快照，
不再逐笔查询收支；按固定记录 ID 上传新内核快照。
创建者使用私有数据库，受邀配偶使用共享数据库。两人同时更新时通过 CloudKit change tag
检测冲突并明确报错，不覆盖对方数据；保留副本后核对重试。
只有主动启用对应账本的同步或共享时，结构化账目才会上传。

这是早期的小规模单记录快照存储，最大 900 KB；超限明确失败，不截断或丢记录。
长期使用前需要升级增量 / 分记录同步。新内核快照与旧原型 `Entry` 记录独立，
目前没有自动迁移；发现缺少美元财务快照的旧账本会提示且不改动原记录，不能把两套金额混合分析。

**尚未完成：**拍照、银行导入与核对页面、工资 / 存款页面，以及 iPhone
真实收据 / 银行文件测试、Wallet 权限及两人真实 iCloud 同步验收。
现有原型已通过 iOS 模拟器编译、安装和启动检查，但不能声称完整需求已经接通、
可在真机正常记账或可上传 TestFlight。

## 安装与配置

1. 从 Mac App Store 安装 Xcode 16 或更新版本；已安装则打开 Xcode，自行阅读并接受许可，完成组件安装。
2. 打开 [FriendLedger.xcodeproj](FriendLedger.xcodeproj)，选择 FriendLedger target。
3. 在 Signing & Capabilities 中选择你的开发团队，改用唯一的 Bundle Identifier，
   例如 `com.yourname.FriendLedger`。TestFlight 需要有效的 Apple Developer Program 会员资格。
4. 在 Build Settings 中将 Debug / Release 的 `ICLOUD_CONTAINER_IDENTIFIER`
   改成自己的容器标识，例如 `iCloud.com.yourname.FriendLedger`。
5. 在 Signing & Capabilities 的 iCloud 中开启 CloudKit，并选择 / 创建同名容器。
   [Info.plist](Config/Info.plist) 和 [entitlements](Config/FriendLedger.entitlements)
   均引用上述变量。不要填写账号密码或私钥到源码里。
6. 需要同步的测试 iPhone 登录 iCloud，并在 App 内主动开启同步。使用不同 Apple ID 的两台真机验证共享；
   如果遇到“拒绝权限”，检查账号、签名、容器和成员权限。

仅试用本地功能时无需配置 CloudKit 容器；真机安装仍需相应开发签名。
默认容器 `iCloud.com.example.FriendLedger` 是占位配置。主动开启同步遇到它会在界面显示配置提示，
不构造不可用的 CloudKit 容器，避免未签名启动时因缺少 entitlement 而直接退出。
替换为真实配置后，运行 CloudKit 仍必须正确签名并启用 iCloud capability；
`CODE_SIGNING_ALLOWED=NO` 仅用于编译验证，不用于真实同步测试。

## CloudKit 开发环境初始化

首次开启同步前，在 CloudKit Console 的 **Development** 数据库创建以下记录类型：

- `Ledger`：`name` 为 String。
- 旧原型的 `Entry`：`amountCents` 为 Int64，`kind` / `category` / `note` / `author` 为 String，
  `date` 为 Date/Time。
- 仅使用旧原型查询接口时，给 `Entry` 的系统字段 `recordName` 添加 **QUERYABLE** 索引。
- 新内核使用 `HouseholdBook` 类型，字段 `payload` 为 String；按固定记录 ID 读写，不需要查询索引。

本应用不使用 Public Database。保留私有 / 共享记录的默认权限，不要为了排错开放公共读写。
`CKShare` 使用 Apple 的系统类型，不要手工创建一个同名自定义类型。

开发环境类型也可由首次保存产生，但首次查询前仍需要正确类型及索引。
上传 TestFlight 前，将 schema 和索引 **Deploy Schema Changes** 到 Production；
开发数据库的实际账目不会复制到生产数据库，TestFlight 使用生产环境。

## 本地验证

```sh
swift run LedgerCoreChecks
swift run ReceiptOCRChecks
plutil -lint Config/Info.plist Config/FriendLedger.entitlements FriendLedger.xcodeproj/project.pbxproj
```

核心检查使用无第三方依赖的可执行测试程序，覆盖金额、收据去重、不重复计账、工资扣款、
当地月份边界、独立存款流水、汇率、序列化、银行确定 / 疑似重复、入账状态变化、
两个导入顺序的收据 / 工资关联、CSV 错误行继续处理及旧快照兼容，以及本地持久化、备份排除、
损坏缓存、写入失败、账号绑定、关闭同步、上传期间编辑和冲突保留。OCR 检查在内存生成测试收据图片，
实际调用本机 Vision，验证商品、税额、总额、照片指纹、EXIF 方向、取消和无效图片错误，
不保存测试照片。当前环境已通过全部 178 项核心检查及本机 OCR 检查；
200 条记录的本地保存加重读实测约 0.005 秒，检查要求小于 1 秒。
Xcode 27.2 / iOS 27.2 已通过 Debug 和 Release 模拟器构建，包含 FinanceKit iOS 分支。
全部 3 项 UI 自动化已通过，使用独立测试缓存和称呼设置，检查本地创建 / 记账 / 重开、
默认不连接云端、配置失败后仍能本地保存，以及模拟 60 秒连接时顶部动画仍显示且本地记账能在连接完成前保存。
慢连接使用仅 Debug 的测试替身，不代表真实 iCloud 网络测量。
这些检查不等同于真实商家收据识别准确率、真实银行流水覆盖率、Wallet 读取或真机同步验收。
如果仅安装 Command Line Tools，Swift 默认 `swiftbuild` 构建引擎报
`Unknown error parsing property list`，给两个 `swift run` 命令加上 `--build-system native`。
该兼容选项在当前工具链可用但已被标记为弃用，安装完整 Xcode 后优先使用默认构建引擎。
如果新安装的 Xcode 尚未完成许可确认，先在 Xcode 界面完成；早期内核验证使用原有
Command Line Tools，可通过命令前加 `DEVELOPER_DIR=/Library/Developer/CommandLineTools`
选择它，不改变系统全局开发工具设置，也没有代用户接受 Xcode 许可。

安装完整 Xcode 后，执行 iOS 模拟器构建：

```sh
xcodebuild -project FriendLedger.xcodeproj -scheme FriendLedger \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

在本地 iPhone 模拟器运行 UI 自动化（将设备名换成已安装的模拟器）：

```sh
xcodebuild -project FriendLedger.xcodeproj -scheme FriendLedger \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

如果命令仍提示使用 Command Line Tools，在 Xcode Settings → Locations 选择正确的
Command Line Tools 版本。

## 两台真机验收（发布前必须完成）

1. A 离线创建账本、添加记录，重开检查本地保存；联网后主动开启同步。
   同 Apple ID 的另一台设备主动从当前 iCloud 加载，核对记录与后续修改。
   再在设置中通过“邀请对方共享账本”向不同 Apple ID 的 B 发邀请。
2. B 安装同一容器的 App；分别在 App 未运行、正在运行时打开邀请并接受。
3. B 应看到同名账本和 A 的记录；B 新增记录，A 下拉刷新后看到相同金额和称呼。
4. 验证连续新增、超过一页的记录、双方删除后汇总；断网时本地保存成功，重连后上传。
   同时编辑出现冲突时双方修改保留，保留独立副本后核对，不静默覆盖。
5. A 停止共享后，B 刷新应提示共享不可用并保留缓存；B 无法继续写入该共享区。
6. 验证 iCloud 退出 / 切换账号、后台返回、重复打开邀请；旧本地账本不丢失且不上传到新账号。
7. Production schema 部署后，通过 TestFlight 用两个 Apple ID 重复上述流程。

## TestFlight

在 App Store Connect 新建与 Bundle Identifier 一致的 App。选择真机 / Any iOS Device，
Product → Archive，再通过 Organizer 上传构建。内部测试成员需要 App Store Connect 权限；
普通朋友通常使用外部测试邀请，首个外部测试构建可能需要 Beta App Review。
上传前还需添加正式 App 图标、填写隐私政策、测试信息和正确的数据收集声明，
并完成生产环境真机验收。这些发布配置尚未代办。

## 第一版边界

- 本地有待上传队列；同步仍是前台核对和网络上传，不是后台实时推送。
- 共享成员默认可读写，称呼是自己填写的，不是实名或经过验证的身份。
- 内核识别是本地 OCR 加保守规则，不是理解任意收据版式的云端大模型。
- 暂无地图查询、商品品牌数据库、通用银行直连、年度税务计算、AA 结算或投资分析。
- 银行导入能帮助补账对账，但不能保证绝不漏账；须覆盖所有账户和账期，并处理所有错误与待核对记录。
- 尚未完成全部页面、实际商家样本准确率测试、真实双账号同步或 TestFlight 发布准备。
