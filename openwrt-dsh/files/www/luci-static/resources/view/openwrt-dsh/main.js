/* openwrt-dsh LuCI 主视图：状态总览 / 一键安装·更新·卸载 / 校验修复 / Web 界面(dsh web 服务) / 软件包自更新(GitHub) / 上传包安装 / 设置
 * 数据面：rpcd 后端 luci.openwrt-dsh(status/log/install/update/doctor/uninstall/migrate/localinstall/check_update/check_dsh/web_set/selfupdate/listdir/mkdir)；配置面：UCI openwrt-dsh。
 * 轮询 2s 拉状态；版本读安装期落盘的标记文件，轮询不拉起 node(路由器上 node 启动以秒计)。
 * 「更新 dsh」先查 npm 源最新版(check_dsh)，确认有新版才弹「更新到 X」确认框。
 * Web 界面区：启/停 dsh web 服务(procd)，「打开」按钮仅已安装时显示、运行且拿到
 * 带令牌链接才可点（链接由后端从服务启动行提取，随 2s 轮询透出）。
 * 任务「执行过程」子窗口：起后台任务(安装/更新/doctor/卸载/迁移/自更新/上传安装)即弹
 * 终端样态弹窗，1s 自轮询 rpc log(后端 64KB 日志尾,\r 进度行已被后端展开成行)实时显示
 * 执行过程；收起窗口不断任务，任务进行中可点状态区「查看执行过程」重开(见 openTaskTerminal)。 */

'use strict';
'require view';
'require rpc';
'require uci';
'require poll';
'require ui';
'require request';

var callStatus = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'status',
	expect: { '': {} }
});

/* 任务日志尾（64KB）：「执行过程」子窗口的数据面。与 status 快照里的 8KB 尾同一
 * 文件不同量——弹窗要看全执行过程给大尾巴，页面 2s 轮询保持小尾巴即可 */
var callLog = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'log',
	expect: { '': {} }
});

/* 安装/更新不带版本参数（版本输入框已删，固定装最新版）。后端的 version 参数仍保留
 * （CLI/接口兼容，留空 = 最新版），这里不传即走无参形态，同 doctor 的调用一样 */
var callInstall = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'install',
	expect: { status: '' }
});

var callUpdate = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'update',
	expect: { status: '' }
});

var callDoctor = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'doctor',
	expect: { status: '' }
});

var callUninstall = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'uninstall',
	params: [ 'runtime' ],
	expect: { status: '' }
});

/* 安装目录迁移：把已装的 dsh 与托管运行时整体搬到目标目录（后台任务；引擎侧
 * 先暂存整拷→校验→改 UCI→删旧，失败旧目录分毫不动）。仅已安装时可发起 */
var callMigrate = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'migrate',
	params: [ 'target' ],
	expect: { status: '' }
});

/* 软件包自更新：check_update 同步查 GitHub（后端限时两跳共 24s），selfupdate 走后台任务 */
var callCheckUpdate = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'check_update',
	expect: { '': {} }
});

/* dsh 运行时更新检查：「更新 dsh」按钮的前置检查（同步查 npm 源上 @deepseek-ai/dsh
 * 最新版，后端单跳限 12s；与本插件包的 GitHub 检查是两条独立的链） */
var callCheckDsh = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'check_dsh',
	expect: { '': {} }
});

var callSelfupdate = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'selfupdate',
	expect: { status: '' }
});

/* 上传包本地安装：ipk 已由 LuCI 经 cgi-io 传到 /etc/luci-uploads 固定落点（见
 * IPK_UPLOAD_PATH），这里只负责让后端起任务去 opkg 安装它（升级/降级/重装均可） */
var callLocalInstall = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'localinstall',
	params: [ 'path' ],
	expect: { status: '' }
});

/* 上传通道固定落点：cgi-io 的落盘路径受会话 ACL 按路径管控（luci-base 只放行
 * /etc/luci-uploads/*，传 /tmp 会被拒——2026-10-19 容器实测「Access to path denied
 * by ACL」），所以前端固定写这一个文件名；rpcd 桥/task.sh/localinstall.sh 三道闸
 * 都按它白名单。目录本体归 luci-base 包（.placeholder），随依赖必然存在 */
var IPK_UPLOAD_PATH = '/etc/luci-uploads/openwrt-dsh-upload.ipk';

/* dsh Web 服务启/停（Web 界面区开关）：后端同步写 UCI 并托管 init 脚本
 * enable/disable + start/stop；procd 拉起是异步的，运行状态以 2s 轮询的
 * web_running/web_url 为准（这里不追认成功）。取全量应答对象而非只挑
 * status 字段：port_busy（§25 端口预检拒启）还带 port/detail 占用线索，
 * 只取 status 就丢了弹窗要用的正文 */
var callWebSet = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'web_set',
	params: [ 'on' ],
	expect: { '': {} }
});

/* 图形化选安装目录：后端列子目录（带挂载点/内存盘/可用空间标注）+ 新建文件夹 */
var callListDir = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'listdir',
	params: [ 'path' ],
	expect: { '': {} }
});

var callMkdir = rpc.declare({
	object: 'luci.openwrt-dsh',
	method: 'mkdir',
	params: [ 'dir', 'name' ],
	expect: { '': {} }
});

function fmtBytes(n) {
	n = parseInt(n, 10) || 0;
	var units = [ 'B', 'KB', 'MB', 'GB', 'TB' ], i = 0;
	while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
	return (i === 0 ? Math.round(n) : n.toFixed(1)) + ' ' + units[i];
}

/* 三段数字版本比较 a >= b（与引擎 odw_node_ge 同义）。仅用于状态行「可更新」标记的
 * 展示修正：检查缓存是检查那一刻的结果，任务装完新版后缓存不会立刻重查——本机版本
 * 已追平/超过缓存里的 latest 时不能还显示「可更新到旧版」 */
function verGe(a, b) {
	var xa = String(a || '').split('.'), xb = String(b || '').split('.');
	for (var i = 0; i < 3; i++) {
		var na = parseInt(xa[i], 10) || 0, nb = parseInt(xb[i], 10) || 0;
		if (na > nb) { return true; }
		if (na < nb) { return false; }
	}
	return true;
}

return view.extend({
	cells: {},

	statusRow: function(key, label) {
		var span = E('span', { 'id': 'odw-' + key }, '…');
		this.cells[key] = span;
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '33%' }, [ label ]),
			E('td', { 'class': 'td left' }, [ span ])
		]);
	},

	/* 弹窗按钮栏必须放在 children 里（button-row），绝不能走 showModal 的第三参：
	 * 2026 起 LuCI master 把 showModal 改成 (title, children, ...classes)——第三参会整包
	 * 塞进 classList.add()，传按钮数组直接抛 InvalidCharacterError：弹窗空白、
	 * 按钮永久转圈（新 createHandlerFn 先加 spinning 再调函数，函数一抛异常
	 * finally 挂不上）。旧版 LuCI 给第三参按钮套的正是 button-row，两种版本通吃。 */
	/* 「更新 dsh」不是直接起任务：先同步查 npm 源最新版（按钮转圈即检查中，后端
	 * 单跳限 12s），确认真有新版才弹「更新到 X」确认框；已是最新/查不到只给通知。
	 * 「安装 dsh」（未装）没有「检查更新」可言，直接走安装确认弹窗。 */
	handleAction: function(ev, action) {
		if (action != 'update') {
			this.confirmInstall();
			return;
		}
		return callCheckDsh().then(L.bind(function(res) {
			if (!res || !res.status) {
				ui.addNotification(null, E('p', {}, _('检查更新失败：后端无响应。')), 'error');
				return;
			}
			if (res.status != 'ok') {
				ui.addNotification(null, E('p', {}, _('检查更新失败：%s。请稍后重试，或检查「设置」里的 npm 源。').format(res.error || _('未知错误'))), 'error');
				return;
			}
			if (res.available == 'no') {
				ui.addNotification(null, E('p', {}, _('已是最新版本 %s，无需更新。').format(res.latest)), 'success');
				return;
			}
			this.confirmDshUpdate(res.latest, res.installed, res.available == 'yes');
		}, this)).catch(L.bind(function() {
			ui.addNotification(null, E('p', {}, _('检查更新请求失败（网络或后端异常），未开始更新。')), 'error');
		}, this));
	},

	/* 检查确认有新版后的更新确认弹窗：只有走到这里（available=yes/unknown）才出现
	 * 「更新到 X」按钮，点了才真正起 update 后台任务。unknown = 版本标记缺失无法
	 * 比对（裸装等），仍允许更新，文案说明即可。 */
	confirmDshUpdate: function(latest, installed, known) {
		ui.showModal(_('更新 dsh'), [
			E('p', {}, known
				? _('发现新版本 %s（当前 %s）。').format(latest, installed || '?')
				: _('无法确定当前已装版本（版本标记缺失），npm 源最新版为 %s。').format(latest)),
			E('p', {}, _('将更新 dsh 到 %s，过程约数分钟（下载运行时与依赖），期间请勿关闭任务。').format(latest)),
			E('div', { 'class': 'button-row' }, [
				E('button', {
					'class': 'btn cbi-button-positive important',
					'click': ui.createHandlerFn(this, function() {
						ui.hideModal();
						return callUpdate().then(L.bind(function(res) {
							if (res == 'started') {
								this.openTaskTerminal(_('更新 dsh'));
							} else if (res == 'busy') {
								ui.addNotification(null, E('p', {}, _('已有任务在运行，请等待其完成。')), 'warning');
							}
						}, this));
					})
				}, _('更新到 ' + latest)),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消'))
			])
		]);
	},

	/* 安装确认弹窗（未装时的「安装 dsh」入口）：装最新版，无需检查 */
	confirmInstall: function() {
		ui.showModal(_('安装 dsh'), [
			E('p', {}, _('将安装最新版 dsh，过程约数分钟（下载运行时与依赖），期间请勿关闭任务。')),
			E('div', { 'class': 'button-row' }, [
				E('button', {
					'class': 'btn cbi-button-positive important',
					'click': ui.createHandlerFn(this, function() {
						ui.hideModal();
						return callInstall().then(L.bind(function(res) {
							if (res == 'started') {
								this.openTaskTerminal(_('安装 dsh'));
							} else if (res == 'busy') {
								ui.addNotification(null, E('p', {}, _('已有任务在运行，请等待其完成。')), 'warning');
							}
						}, this));
					})
				}, _('安装')),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消'))
			])
		]);
	},

	/* 任务「执行过程」子窗口（终端样态）：所有后台任务起跑后弹出的实时日志视图——
	 * 用户要的是「点完能看到在干什么」，而不是对着状态表一行字等。数据面 = rpc log
	 * （后端给 64KB 日志尾；\r 进度行已被后端展开成行、ESC 清色序列已删，这里
	 * textContent 直填，无注入面）。轮询形态 = tail -f：1s 一拍整窗替换日志尾 +
	 * 贴底自动滚动（用户往上翻了就不拖，回到底部继续贴）。窗口纯「看」：收起不
	 * 影响后台任务，任务进行中可经状态区「查看执行过程」重开；本窗口有自己的 1s
	 * 轮询（log + status），与页面 2s 轮询互不干扰——status.sh 是纯文件读快路径，
	 * 任务期间的短暂双轮询对路由器无压力。
	 * 终局判定过「新鲜闸」：开窗瞬间页面轮询可能还揣着上一个任务的 done/failed
	 * 旧快照，只认 seenRunning（本窗口亲眼见过 running）或 task_ts 晚于开窗时刻
	 * （状态是开窗后才落盘的），否则停在「执行中」直到见到 running——绝不开窗
	 * 即误报「上次任务完成」。 */
	openTaskTerminal: function(title) {
		var state = { seenRunning: false, finished: false, openedAt: Date.now(), timer: null };

		var pane = E('div', {
			'class': 'odw-term',
			'style': 'background:#141414; color:#d6d6d6; font-family:monospace; font-size:12px; line-height:1.5;' +
				'padding:10px 12px; height:320px; overflow-y:auto; white-space:pre-wrap; word-break:break-all;' +
				'border-radius:4px; margin-top:4px'
		}, '');

		var statusLine = E('div', { 'id': 'odw-term-status', 'style': 'margin-top:8px; font-weight:bold' },
			_('任务启动中…'));

		function alive() { return document.body.contains(pane); }
		function atBottom() { return pane.scrollTop + pane.clientHeight >= pane.scrollHeight - 48; }
		function showLog(text) {
			var stick = atBottom();
			pane.textContent = text || _('（暂无日志输出）');
			if (stick) { pane.scrollTop = pane.scrollHeight; }
		}

		function tick() {
			/* 弹窗被任一途径关掉（收起按钮/Esc/被新弹窗替换）→ 停表；finished 后也停 */
			if (!alive() || state.finished) {
				if (state.timer) { clearInterval(state.timer); }
				return;
			}
			callLog().then(function(res) {
				if (alive()) { showLog((res && res.log) || ''); }
			}).catch(function() {
				if (alive()) { statusLine.textContent = _('读取任务日志失败（rpc 异常），持续重试中…'); }
			});
			callStatus().then(function(st) {
				if (!alive() || state.finished || !st || !st.task_phase) { return; }
				if (st.task_phase == 'running') {
					state.seenRunning = true;
					statusLine.textContent = _('⏳ 任务执行中…（1s 刷新）');
					return;
				}
				if (st.task_phase != 'done' && st.task_phase != 'failed') { return; }
				var fresh = st.task_ts && (parseInt(st.task_ts, 10) * 1000 >= state.openedAt - 2000);
				if (!state.seenRunning && !fresh) { return; } /* 上一任务的旧快照，不认 */
				state.finished = true;
				clearInterval(state.timer);
				statusLine.textContent = (st.task_phase == 'done')
					? _('✓ 任务完成')
					: _('✗ 任务失败（退出码 %s）').format(st.task_rc || '?');
				/* 终局与最后一次日志可能错拍（log/status 并发请求），补拉一次日志尾 */
				callLog().then(function(r2) {
					if (alive()) { showLog((r2 && r2.log) || ''); }
				}).catch(function() {});
			});
		}
		state.timer = setInterval(tick, 1000);

		/* 按钮栏走 children 内 button-row（showModal 第三参在新 LuCI 是 class 名，见 §17）。
		 * 轮询必须在 showModal 之后才起拍：tick 第一行的 alive() 探测 pane 是否在 DOM，
		 * 先起拍的话开窗前的那一拍会把自己 clearInterval（真浏览器回归实锤过的
		 * 「窗口天生失聪」：日志空、终局行永不出） */
		ui.showModal(title + ' — ' + _('执行过程'), E('div', {}, [
			E('p', { 'style': 'color:#777; margin-bottom:4px' },
				_('任务在后台执行，收起本窗口不会中断；任务进行中可从状态区「查看执行过程」重新打开。')),
			pane,
			statusLine,
			E('div', { 'class': 'button-row' }, [
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': function() {
						clearInterval(state.timer);
						ui.hideModal();
					}
				}, _('收起窗口'))
			])
		]));
		tick();
	},

	/* 状态区「查看执行过程」：任务进行中重开执行过程窗口（标题按任务名映射，见 applyStatus） */
	handleWatch: function() {
		if (this.lastTaskTitle) { this.openTaskTerminal(this.lastTaskTitle); }
	},

	handleDoctor: function(ev) {
		ui.showModal(_('校验修复（doctor）'), [
			E('p', {}, _(
				'对已安装的 dsh 做实载校验并尽力修复（koffi/node-pty 原生件、运行时垫片、版本标记），' +
				'不改变 dsh 版本。适合「官方 npm i -g 安装后补 musl 修复」或安装后异常自查。')),
			E('div', { 'class': 'button-row' }, [
				E('button', {
					'class': 'btn cbi-button-action important',
					'click': ui.createHandlerFn(this, function() {
						ui.hideModal();
						return callDoctor().then(L.bind(function(res) {
							if (res == 'started') {
								this.openTaskTerminal(_('校验修复（doctor）'));
							} else if (res == 'busy') {
								ui.addNotification(null, E('p', {}, _('已有任务在运行，请等待其完成。')), 'warning');
							}
						}, this));
					})
				}, _('开始校验')),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消'))
			])
		]);
	},

	/* 卸载 dsh：默认保留托管 Node 运行时（重装免下载）；勾选后连运行时一起清（释放空间）。
	 * /usr/bin/dsh 入口与 LuCI 页面归 openwrt-dsh 包管，不随卸载消失。 */
	handleUninstall: function(ev) {
		var chkRuntime = E('input', { 'type': 'checkbox', 'id': 'odw-uninstall-runtime' });
		ui.showModal(_('卸载 dsh'), E('div', {}, [
			E('p', {}, _('将移除已安装的 dsh 与版本标记。默认保留 Node 运行时，下次安装无需重新下载。')),
			E('p', {}, [
				chkRuntime, ' ',
				E('label', { 'for': 'odw-uninstall-runtime' },
					_('同时删除 Node 运行时（释放全部空间；重装需重新下载约 300MB）'))
			]),
			E('p', { 'style': 'color:#777' }, _(
				'/usr/bin/dsh 入口与 LuCI 页面随本插件保留；卸载后再调用 dsh 会提示「尚未安装」。' +
				'卸载期间 dsh 不可用，进行中的任务请先等它结束。')),
			E('div', { 'class': 'button-row' }, [
				E('button', {
					'class': 'btn cbi-button-negative important',
					'click': ui.createHandlerFn(this, function() {
						var purge = chkRuntime.checked ? '1' : '';
						ui.hideModal();
						return callUninstall(purge).then(L.bind(function(res) {
							if (res == 'started') {
								this.openTaskTerminal(_('卸载 dsh'));
							} else if (res == 'busy') {
								ui.addNotification(null, E('p', {}, _('已有任务在运行，请等待其完成。')), 'warning');
							}
						}, this));
					})
				}, _('确认卸载')),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消'))
			])
		]));
	},

	/* 软件包自更新（GitHub Releases）：检查是只读查询（同步 rpc，立即返回结果），
	 * 立即更新走后台任务（下载 ipk → sha256 → opkg 安装），进度看状态表「任务状态」行 */
	handleCheckUpdate: function(ev) {
		return callCheckUpdate().then(L.bind(function(res) {
			if (!res || !res.status) {
				ui.addNotification(null, E('p', {}, _('检查更新失败：后端无响应。')), 'error');
				return;
			}
			if (res.status != 'ok') {
				ui.addNotification(null, E('p', {}, _('检查失败：%s').format(res.error || _('未知错误'))), 'error');
				return;
			}
			if (res.available == 'yes') {
				ui.addNotification(null, E('p', {}, _('发现新版本 %s（当前 %s），可点「立即更新」。').format(res.latest, res.installed)), 'info');
			} else if (res.available == 'no') {
				ui.addNotification(null, E('p', {}, _('已是最新版本 %s。').format(res.latest)), 'success');
			} else {
				ui.addNotification(null, E('p', {}, _('最新发布 %s；本机包版本未知（opkg 无记录），如需安装可点「立即更新」。').format(res.latest)), 'warning');
			}
		}, this)).catch(L.bind(function() {
			ui.addNotification(null, E('p', {}, _('检查更新请求失败（网络或后端异常）。')), 'error');
		}, this));
	},

	handleSelfupdate: function(ev) {
		var known = this.lastGh || '';
		ui.showModal(_('立即更新软件包'), E('div', {}, [
			E('p', {}, _('将从 GitHub Releases 下载最新 ipk，sha256 校验后用 opkg 安装升级本插件（不影响已装的 dsh 与 Node 运行时）。')),
			E('p', { 'style': 'color:#777' }, known
				? _('目标版本：%s（任务执行时会再核对一次）。完成后请刷新浏览器页面加载新界面。').format(known)
				: _('建议先点「检查更新」确认有新版（任务执行时也会再核对）。完成后请刷新浏览器页面。')),
			E('div', { 'class': 'button-row' }, [
				E('button', {
					'class': 'btn cbi-button-positive important',
					'click': ui.createHandlerFn(this, function() {
						ui.hideModal();
						return callSelfupdate().then(L.bind(function(res) {
							if (res == 'started') {
								this.openTaskTerminal(_('软件包自更新'));
							} else if (res == 'busy') {
								ui.addNotification(null, E('p', {}, _('已有任务在运行，请等待其完成。')), 'warning');
							}
						}, this));
					})
				}, _('开始更新')),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消'))
			])
		]));
	},

	/* Web 界面区：启/停 dsh web 服务。后端 web_set 是同步的（uci+init 毫秒级），
	 * procd 拉起/停止是异步的——按钮文案不在这里追认，交给 2s 轮询刷出真实状态。
	 * 失败一律弹窗（用户口径「出错了要看得见」）：2026-10-20 之前后端曾对 conffile
	 * 丢段静默无效果（porting-notes §24），用户点按钮全程零反馈，通知条都太轻 */
	handleWebToggle: function(ev) {
		var on = this.webEnabled ? '0' : '1';
		var self = this;
		return callWebSet(on).then(function(res) {
			/* 应答是全量对象（§25），各分支统一按 res.status 判 */
			var st = (res && res.status) ? res.status : '';
			if (st == 'ok') {
				if (on == '1') {
					ui.addNotification(null, E('p', {}, _('启用指令已受理，正在拉起 dsh Web 服务…')), 'info');
					self.watchWebStart();
				} else {
					ui.addNotification(null, E('p', {}, _('Web 服务已停用（含开机自启）。')), 'info');
				}
				return;
			}
			if (st == 'not_installed') {
				self.showWebFailModal(_('尚未安装 dsh，无法启用 Web 服务。'),
					_('先在上方安装 dsh，再回来开启 Web 服务。'));
				return;
			}
			if (st == 'no_init') {
				self.showWebFailModal(_('init 脚本缺失（/etc/init.d/openwrt-dsh-web）。'),
					_('openwrt-dsh 包安装不完整：请点上方「校验修复」，或重装插件后重试。'));
				return;
			}
			if (st == 'port_busy') {
				/* §25 端口预检拒启：后端在受理前就拦下（不让服务进「秒崩→respawn
				 * 5 次→放弃」的盲区），detail 带 netstat 占用行。页面已无端口输入框
				 * （端口全自动），固定端口只可能来自手工 UCI 配置 */
				self.showWebFailModal(
					_('监听端口 %s 已被占用，已拒绝启用。').format((res && res.port) || _('未知')),
					(res && res.detail) || _('端口被其他程序占用。'),
					_('停掉占用该端口的程序后重新点「启用」；若在 UCI 里手工配过固定端口（openwrt-dsh.web.port），删除该选项即回到自动选端口。'));
				return;
			}
			self.showWebFailModal(_('操作失败（后端返回：%s）。').format(st || _('无响应')),
				_('请刷新页面重试；持续失败请刷新登录后再试。'));
		}).catch(function() {
			self.showWebFailModal(_('请求失败（网络或后端异常）。'),
				_('LuCI 会话可能已过期：刷新页面重新登录后再试。'));
		});
	},

	/* 启用后的启动结果守望：procd 拉起是异步的，「启用受理成功」≠ 服务跑得起来
	 * （端口被占等崩溃要几秒后才定局，procd respawn 5 次放弃才注销实例）。这里
	 * 1s 一拍追问 status，最多 20 拍：跑起来（或用户已停用）就收工；web_error
	 * 一出现立刻弹窗把原因拍在用户面前——此前这里全程沉默，用户只看到永远
	 * 不来的「运行中」。单拍失败忽略，下一拍再试 */
	watchWebStart: function() {
		var self = this;
		var timer = setInterval(function() {
			callStatus().then(function(st) {
				/* 换了新守望（连点）/页面已离开：旧的一拍就地自停 */
				if (self._webWatch != timer || !document.body) { clearInterval(timer); return; }
				if (st.web_running == '1' || st.web_enabled != '1') { clearInterval(timer); return; }
				if (st.web_error) {
					clearInterval(timer);
					self.showWebFailModal(_('dsh Web 服务启动失败'), st.web_error);
					return;
				}
				if (self._webWatchTick >= 20) {
					clearInterval(timer);
					ui.addNotification(null, E('p', {}, _('dsh Web 服务尚未就绪；若状态行持续显示未运行，失败原因会直接显示在状态行。')), 'warning');
					return;
				}
				self._webWatchTick++;
			}).catch(function() { /* 下一拍再试 */ });
		}, 1000);
		this._webWatch = timer;
		this._webWatchTick = 0;
	},

	/* Web 服务失败的弹窗（§17 纪律：按钮栏必须在 children 的 button-row 里，
	 * showModal 只给两参——第三参在新 LuCI 会整包进 classList 炸掉弹窗）。
	 * title=主文案；detail=原因/建议（等宽块展示，服务输出原文也走这里）；
	 * extra=可省的补充提示，缺省给常见原因清单 */
	showWebFailModal: function(title, detail, extra) {
		var kids = [
			E('h4', {}, title),
			E('p', {
				'style': 'font-family:monospace; white-space:pre-wrap; word-break:break-all; ' +
					'background:#f6f6f6; border:1px solid #ddd; border-radius:4px; padding:6px; margin:6px 0'
			}, [ detail ])
		];
		kids.push(E('p', {}, extra || _(
			'常见原因：端口被占用——停掉占用端口的程序后重新启用（服务缺省每次启动自动选空闲端口）；' +
			'或 dsh 运行时损坏——点上方「校验修复」。')));
		kids.push(E('div', { 'class': 'button-row' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, _('知道了'))
		]));
		ui.showModal(_('dsh Web 服务'), E('div', {}, kids));
	},

	/* 「打开」：新标签页直达带令牌的 dsh Web 界面。地址取法见 applyStatus 的
	 * openUrl 计算（IP 字面量优先）。令牌等同于「操作路由器的钥匙」，不做
	 * 复制/展示扩散，只提供即点即开 */
	handleOpen: function(ev) {
		if (!this.openUrl) { return; }
		window.open(this.openUrl, '_blank', 'noopener');
	},

	/* 局域网设置解锁（§26→2026-10-21 拍板）：补丁默认涂抹（install/update/doctor
	 * 无条件重涂），页面无开关——曾有的「局域网设置解锁」开关与确认框已删。dsh 的
	 * 设置页只认本机回环打开的页面，LAN IP 打开时整页拒载；放行它由引擎侧自动完成，
	 * 状态只透过 status 的 web_remote_state 透出（防锚点漂移可查） */

	/* 上传包安装（「上传安装」按钮 / 拖 ipk 到按钮上）：
	 * 链路 = 前端校验文件名/大小 → 确认弹窗 → cgi-io 上传（/cgi-upload，落盘路径受
	 * ACL 白名单管控，只能进 /etc/luci-uploads/）→ rpc 起后台任务 opkg 安装。
	 * 上传不用 ui.uploadFile：那是 24.10 才有的 helper（自带选文件弹窗，和拖放对不上），
	 * 直接用两版 LuCI 都有的 request.post + FormData（22.03 自家 ui.js 同款用法）。
	 * cgi-io 的失败应答是 HTTP 200 + { failure: [...] }（response() 恒打 Status: 200），
	 * 必须看 body 的 failure 字段，不能靠 reject 路径。 */

	/* 点按钮 → 打开文件选择框（accept 只过滤 .ipk，真正的校验在 handleUploadPicked） */
	handleUploadClick: function(ev) {
		this.ipkInput.click();
	},

	/* 拿到文件（选框或拖放共用）：多一道确认闸——opkg 会毫不犹豫地升级/降级/重装
	 * 整个插件，文件名/大小/版本先亮出来让用户过目 */
	handleUploadPicked: function(file) {
		if (!file) { return; }
		if (this.taskRunning) {
			ui.addNotification(null, E('p', {}, _('已有任务在运行，请等待其完成再上传安装。')), 'warning');
			return;
		}
		var m = file.name.match(/^openwrt-dsh_([A-Za-z0-9._-]+)\.ipk$/i);
		if (!m) {
			ui.addNotification(null, E('p', {}, _('只支持安装 openwrt-dsh 的 ipk 包（文件名形如 openwrt-dsh_0.1.0-r12_all.ipk）。')), 'error');
			return;
		}
		if (file.size > 8 * 1024 * 1024) {
			/* 本插件 ipk 只有几十 KB；超大的几乎肯定是拿错文件。上传会整个落进 /tmp
			 * 的 tmpfs（cgi-io 的 O_TMPFILE 临时文件在内存里），大文件会顶爆路由器内存 */
			ui.addNotification(null, E('p', {}, _('文件超过 8MB（本插件 ipk 只有几十 KB），已拒绝，请确认选的是正确的 ipk。')), 'error');
			return;
		}
		var self = this;
		ui.showModal(_('上传安装 openwrt-dsh 包'), E('div', {}, [
			E('p', {}, _('将把本机 ipk 上传到路由器并用 opkg 安装（升级/降级/重装均可，opkg 不做版本拦截）：')),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, _('文件')),
					E('td', { 'class': 'td left' }, file.name)
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, _('大小')),
					E('td', { 'class': 'td left' }, fmtBytes(file.size))
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, _('包内版本（按文件名）')),
					E('td', { 'class': 'td left' }, m[1])
				])
			]),
			E('p', { 'style': 'color:#777' }, _('安装完成后请刷新浏览器页面加载新界面；已装的 dsh 与 Node 运行时不受影响。')),
			E('div', { 'class': 'button-row' }, [
				E('button', {
					'class': 'btn cbi-button-positive important',
					'click': ui.createHandlerFn(this, function() {
						ui.hideModal();
						return self.doUploadInstall(file, m[1]);
					})
				}, _('上传并安装')),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消'))
			])
		]));
	},

	/* 上传 + 起任务：进度条弹窗 → cgi-upload → localinstall 后台任务 */
	doUploadInstall: function(file, ver) {
		var self = this;
		var bar = E('div', { 'class': 'cbi-progressbar', 'title': '0%' }, E('div', { 'style': 'width:0' }));
		var pct = E('span', { 'style': 'margin-left:8px; white-space:nowrap' }, '0%');
		ui.showModal(_('正在上传 ipk…'), E('div', {}, [
			E('p', {}, _('文件：%s').format(file.name)),
			E('div', { 'style': 'display:flex; align-items:center' }, [ bar, pct ])
		]));

		var data = new FormData();
		data.append('sessionid', rpc.getSessionID());
		data.append('filename', IPK_UPLOAD_PATH);
		data.append('filedata', file);

		return request.post(L.env.cgi_base + '/cgi-upload', data, {
			timeout: 0,
			progress: function(pev) {
				var p = (pev && pev.total) ? Math.floor(pev.loaded * 100 / pev.total) : 0;
				bar.setAttribute('title', p + '%');
				bar.firstElementChild.style.width = p + '%';
				pct.textContent = p + '%';
			}
		}).then(function(res) {
			var reply = {};
			try { reply = res.json() || {}; } catch (e) { reply = {}; }
			ui.hideModal();
			if (reply.failure) {
				/* 常见于 /tmp 的 tmpfs 不支持 O_TMPFILE 的环境（个别固件），如实报给用户 */
				ui.addNotification(null, E('p', {}, _('上传失败：%s。请重试；多次失败可改用 SSH + opkg 手工安装。').format(reply.message || _('未知错误'))), 'error');
				return;
			}
			return callLocalInstall(IPK_UPLOAD_PATH).then(function(res2) {
				if (res2 == 'started') {
					/* 复位收尾提示标记：上一次的「装完请刷新」提示不该吞掉这一次的 */
					self.localInstallTip = false;
					ui.addNotification(null, E('p', {}, _('上传完成（%s，sha256 %s…），安装任务已启动。').format(fmtBytes(reply.size || 0), String(reply.sha256sum || '').substring(0, 12))), 'info');
					self.openTaskTerminal(_('上传安装'));
				} else if (res2 == 'busy') {
					ui.addNotification(null, E('p', {}, _('已有任务在运行，安装未启动；上传的包已就位，稍后重试即可。')), 'warning');
				} else if (res2 == 'missing_file') {
					ui.addNotification(null, E('p', {}, _('后端找不到上传的包（可能已被清理），请重新上传。')), 'error');
				} else {
					ui.addNotification(null, E('p', {}, _('后端无响应或拒绝请求（%s），请刷新页面后重试。').format(res2 || _('空'))), 'error');
				}
			});
		}).catch(function() {
			ui.hideModal();
			ui.addNotification(null, E('p', {}, _('上传请求失败（网络中断或会话过期，请重新登录 LuCI 后重试）。')), 'error');
		});
	},

	handleSaveConfig: function(ev) {
		/* 任务进行中不收设置：迁移任务收尾时会 commit 新 install_dir，这时保存的
		 * 旧值要么被它覆盖、要么反过来把刚迁好的目录改回去——两头都是坑 */
		if (this.taskRunning) {
			ui.addNotification(null, E('p', {}, _('有任务正在进行，请等它结束再保存设置。')), 'warning');
			return;
		}
		var dir = this.dirInput.value.trim();
		var reg = this.regInput.value.trim();
		var repo = this.repoInput.value.trim();
		var proxy = this.proxyInput.value.trim();
		if (dir && dir.charAt(0) != '/') {
			ui.addNotification(null, E('p', {}, _('安装目录必须是绝对路径（以 / 开头）。')), 'error');
			return;
		}
		if (repo && !/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(repo)) {
			ui.addNotification(null, E('p', {}, _('GitHub 仓库格式应为 owner/repo（字母数字与 . _ -）。')), 'error');
			return;
		}
		if (proxy && !/^https?:\/\//.test(proxy)) {
			ui.addNotification(null, E('p', {}, _('GitHub 加速代理需以 http:// 或 https:// 开头（前缀形态）。')), 'error');
			return;
		}
		uci.set('openwrt-dsh', 'core', 'install_dir', dir || '/opt/openwrt-dsh');
		uci.set('openwrt-dsh', 'core', 'npm_registry', reg);
		uci.set('openwrt-dsh', 'core', 'github_repo', repo || 'StormDAmon/openwrt-dsh');
		uci.set('openwrt-dsh', 'core', 'github_proxy', proxy);
		return uci.save().then(function() {
			return uci.apply().then(function() {
				ui.addNotification(null, E('p', {}, _('设置已保存。对安装目录的修改在下次安装/更新任务时生效（已装内容不会自动搬家，要搬用安装目录旁的「迁移」按钮）；GitHub 仓库与加速代理在下次「检查更新」时生效。')), 'info');
			});
		});
	},

	/* 图形化选目录弹窗（「浏览」选安装目录 / 「迁移」选目标目录共用）：模态弹窗里
	 * 逐层点进目录，选满 300MB 级运行时的落脚点。挂载点条目会标「独立分区/内存盘 +
	 * 可用空间」——路由器 overlay 常偏小，用户真正要找的是数据盘（iStoreOS 通常挂在
	 * /mnt 下）。opts: { title, tip, confirmText, onPick(path) }，onPick 收到最终路径 */
	openDirPicker: function(opts) {
		var self = this;
		var state = { path: '/' };
		/* 起始层：浏览默认停在当前配置的安装目录；迁移是挑「别的」分区，从根开始 */
		var init = (opts.startPath !== undefined) ? opts.startPath : (this.dirInput.value || '').trim();
		if (init.charAt(0) == '/') { state.path = init; }

		var pathEl = E('span', { 'style': 'font-family:monospace; font-weight:bold' }, '…');
		var infoEl = E('span', { 'style': 'color:#777; margin-left:6px' }, '');
		var listBox = E('div', {
			'style': 'margin-top:8px; max-height:320px; overflow:auto; border:1px solid #ddd; border-radius:4px; background:#fff'
		});

		function badge(text, color) {
			return E('span', {
				'style': 'font-size:11px; padding:1px 6px; border-radius:3px; color:#fff; background:' + color +
					'; white-space:nowrap'
			}, text);
		}

		function entryRow(e) {
			var marks = [];
			if (e.mount == '1') {
				marks.push(e.tmpfs == '1' ? badge(_('内存盘'), '#d08000') : badge(_('独立分区'), '#2e7ed6'));
				if (e.free && e.free != '0') {
					marks.push(E('span', { 'style': 'color:#666; font-size:12px; white-space:nowrap' }, fmtBytes(e.free)));
				}
			}
			return E('div', {
				'class': 'odw-diritem',
				'click': function() { go(e.path); }
			}, [ E('span', { 'style': 'font-family:monospace' }, e.name) ].concat(marks));
		}

		function clearBox() {
			while (listBox.firstChild) { listBox.removeChild(listBox.firstChild); }
		}

		function renderList(res) {
			pathEl.textContent = res.path || state.path;
			var bits = [];
			if (res.tmpfs == '1') { bits.push(_('内存盘（tmpfs，重启即失，勿装这里）')); }
			if (res.free) { bits.push(fmtBytes(res.free) + _(' 可用')); }
			infoEl.textContent = bits.length ? '（' + bits.join(' · ') + '）' : '';

			clearBox();
			var es = res.entries || [];
			if (!es.length) {
				listBox.appendChild(E('div', { 'style': 'padding:12px; color:#999' }, _('（这一层没有子目录）')));
				return;
			}
			es.forEach(function(e) { listBox.appendChild(entryRow(e)); });
		}

		function renderError(text) {
			clearBox();
			listBox.appendChild(E('div', { 'style': 'padding:12px; color:#c00' }, text || _('读取失败，请重试。')));
		}

		function parentOf(p) {
			if (p == '/') { return '/'; }
			var i = p.lastIndexOf('/');
			return (i <= 0) ? '/' : p.substring(0, i);
		}

		function go(p, noFallback) {
			listBox.style.opacity = '.5';
			return callListDir(p).then(function(res) {
				listBox.style.opacity = '1';
				if (!res || res.error) {
					/* 起始路径可能已不存在（配置里留着旧目录）：回退到 / 再报错 */
					if (!noFallback && p != '/') {
						state.path = '/';
						go('/', true);
					}
					else {
						renderError(_('无法读取该目录。'));
					}
					return;
				}
				state.path = res.path || p;
				renderList(res);
			}).catch(function() {
				listBox.style.opacity = '1';
				renderError();
			});
		}

		function promptMkdir() {
			var nameInput = E('input', {
				'type': 'text', 'class': 'cbi-input-text',
				'style': 'width:100%', 'placeholder': _('文件夹名称')
			});
			ui.showModal(_('新建文件夹'), E('div', {}, [
				E('p', {}, _('将在 %s 下创建新文件夹。').format(state.path)),
				nameInput,
				E('div', { 'class': 'button-row', 'style': 'margin-top:8px' }, [
					E('button', {
						'class': 'btn cbi-button-important',
						'click': ui.createHandlerFn(self, function() {
							var name = (nameInput.value || '').trim();
							if (!name) { return; }
							return callMkdir(state.path, name).then(function(res) {
								ui.hideModal();
								if (!res || res.error) {
									ui.addNotification(null, E('p', {}, _('创建失败：名称含非法字符（/ . ..）或路径无效。')), 'error');
									return;
								}
								showBrowseModal();
								go(res.path);
							});
						})
					}, _('创建并进入')),
					E('button', { 'class': 'btn', 'click': showBrowseModal }, _('返回'))
				])
			]));
		}

		function showBrowseModal() {
			var quickLinks = [ E('span', { 'style': 'color:#777' }, _('快捷跳转：')) ];
			/* /mnt：iStoreOS 数据盘惯常挂点；/overlay：无数据盘机器上真正有空间的可写分区 */
			[ '/', '/mnt', '/opt', '/overlay' ].forEach(function(q) {
				quickLinks.push(E('a', {
					'href': '#',
					'style': 'margin-left:10px',
					'click': function(ev) { ev.preventDefault(); go(q); }
				}, q));
			});

			/* 按钮栏走 children 内的 button-row（showModal 第三参在新 LuCI 是 class 名，不能放按钮） */
			ui.showModal(opts.title, E('div', {}, [
				E('style', { 'type': 'text/css' },
					'.odw-diritem{display:flex;justify-content:space-between;align-items:center;gap:8px;' +
					'padding:7px 12px;cursor:pointer;border-bottom:1px solid #f2f2f2}' +
					'.odw-diritem:hover{background:#eef5ff}'),
				E('div', {}, [ _('当前目录：'), pathEl, infoEl ]),
				E('div', { 'style': 'margin-top:8px' }, quickLinks),
				listBox,
				E('div', { 'style': 'margin-top:6px; color:#999; font-size:12px' }, opts.tip),
				E('div', { 'class': 'button-row' }, [
					E('button', { 'class': 'btn', 'click': function() { go(parentOf(state.path)); } }, _('⬆ 上一级')),
					E('button', { 'class': 'btn', 'click': function() { go(state.path); } }, _('刷新')),
					E('button', { 'class': 'btn', 'click': promptMkdir }, _('新建文件夹')),
					E('button', {
						'class': 'btn cbi-button-positive important',
						'click': ui.createHandlerFn(self, function() {
							var picked = state.path;
							ui.hideModal();
							opts.onPick.call(self, picked);
						})
					}, opts.confirmText),
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消'))
				])
			]));
		}

		showBrowseModal();
		go(state.path);
	},

	handleBrowse: function() {
		this.openDirPicker({
			title: _('选择安装目录'),
			tip: _('点击子目录进入；选好后点「选择此目录」填入安装目录。'),
			confirmText: _('选择此目录'),
			onPick: function(p) { this.dirInput.value = p; }
		});
	},

	/* 迁移入口：与「浏览」同一个目录弹窗里选目标路径，选完再弹一次确认（写清旧→新与
	 * 影响面）才真正起任务——迁移是数分钟的整目录搬家，中间多一道闸防手滑 */
	handleMigrate: function() {
		this.openDirPicker({
			title: _('选择迁移目标目录'),
			startPath: '/',
			tip: _('点击子目录进入；选好后点「选为迁移目标」（目标需是放得下现有内容的分区，同名内容冲突会拒绝）。'),
			confirmText: _('选为迁移目标'),
			onPick: function(p) { this.confirmMigrate(p); }
		});
	},

	confirmMigrate: function(target) {
		var from = this.lastInstallDir || '';
		ui.showModal(_('迁移 dsh 安装目录'), E('div', {}, [
			E('p', {}, _('将把已安装的 dsh 与 Node 运行时整体搬迁：')),
			E('p', { 'style': 'font-family:monospace' }, [ from || '?', E('br'), '→ ', target ]),
			E('p', {}, _('过程约数分钟（整目录复制 + 校验 + 改配置 + 清理旧目录），期间请勿使用 dsh，也不要关闭任务。完成后安装目录设置会自动更新。')),
			E('div', { 'class': 'button-row' }, [
				E('button', {
					'class': 'btn cbi-button-positive important',
					'click': ui.createHandlerFn(this, function() {
						ui.hideModal();
						return callMigrate(target).then(L.bind(function(res) {
							if (res == 'started') {
								this.openTaskTerminal(_('迁移安装目录'));
							} else if (res == 'busy') {
								ui.addNotification(null, E('p', {}, _('已有任务在运行，请等待其完成。')), 'warning');
							} else if (res == 'invalid_target') {
								ui.addNotification(null, E('p', {}, _('迁移目标路径无效（需以 / 开头的绝对路径，且不含 . .. 段）。')), 'error');
							}
						}, this));
					})
				}, _('开始迁移')),
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消'))
			])
		]));
	},

	render: function() {
		var self = this;

		var banner = E('div', { 'id': 'odw-banner', 'class': 'alert-message hide' });

		/* 插件版本徽标：标题旁显示本插件包自己的版本号（0.1.0-r6 形态）——
		 * 区别于下方状态表里的「dsh 版本」（那是装出来的 dsh 运行时）。
		 * 数据来自 2s 轮询的 status 快照（pkg_version），第一真源是包自带的版本标记文件 */
		this.verBadge = E('span', {
			'id': 'odw-verbadge',
			'style': 'font-size:13px; font-weight:normal; color:#888; margin-left:8px; white-space:nowrap'
		}, '');

		var statusTable = E('table', { 'class': 'table' }, [
			this.statusRow('platform', _('平台 / libc')),
			this.statusRow('install_dir', _('安装目录')),
			this.statusRow('free', _('分区可用空间')),
			this.statusRow('node_version', _('Node 运行时')),
			this.statusRow('dsh_version', _('dsh 版本')),
			this.statusRow('task', _('任务状态')),
			this.statusRow('registry', _('npm 源'))
		]);

		/* 按钮名要一眼看懂是安装功能：状态没读到前就叫「安装 dsh」（置灰），
		 * 读到后才按已装/未装分化成「更新 dsh」/「安装 dsh」——不再用「检查中…」这种
		 * 让人猜不透用途的占位文案。 */
		this.btnTask = E('button', {
			'class': 'btn cbi-button-positive important',
			'title': _('正在读取状态…'),
			'disabled': '',
			'click': ui.createHandlerFn(this, function(ev) {
				var dsh = this.lastDsh;
				self.handleAction(ev, dsh ? 'update' : 'install');
			})
		}, _('安装 dsh'));

		this.btnDoctor = E('button', {
			'class': 'btn cbi-button-action',
			'title': _('校验并尽力修复已安装的 dsh（doctor），不改变版本'),
			'click': ui.createHandlerFn(this, 'handleDoctor')
		}, _('校验修复已装 dsh'));

		this.btnUninstall = E('button', {
			'class': 'btn cbi-button-negative',
			'disabled': '',
			'click': ui.createHandlerFn(this, 'handleUninstall')
		}, _('卸载 dsh'));

		/* 查看执行过程：任务进行中才出现（applyStatus 控制显隐）——关掉过执行过程
		 * 子窗口、或任务起跑后才刷新页面的用户从这里重开窗口，不用对着状态表一行字等 */
		this.btnWatch = E('button', {
			'class': 'btn cbi-button',
			'style': 'display:none',
			'click': ui.createHandlerFn(this, 'handleWatch')
		}, _('查看执行过程'));

		/* Web 界面区：状态行复用 statusRow（2s 轮询刷新），开关与打开按钮走独立 rpc。
		 * 「打开」按钮初始隐藏——已安装 dsh 才显示（本区的需求口径），运行且拿到
		 * 带令牌链接才可点；开关在状态读到前置灰防误点 */
		var webTable = E('table', { 'class': 'table' }, [
			this.statusRow('web_state', _('Web 服务')),
			this.statusRow('web_url', _('访问地址（含令牌）'))
		]);

		this.btnWebToggle = E('button', {
			'class': 'btn cbi-button-action',
			'title': _('正在读取状态…'),
			'disabled': '',
			'click': ui.createHandlerFn(this, 'handleWebToggle')
		}, _('启用 Web 服务'));

		this.btnOpen = E('button', {
			'class': 'btn cbi-button-positive important',
			'style': 'display:none',
			'title': _('服务未运行或访问链接未就绪'),
			'disabled': '',
			'click': ui.createHandlerFn(this, 'handleOpen')
		}, _('打开'));

		/* 局域网设置解锁（§26→2026-10-21 拍板）：补丁默认涂抹、无开关——曾有的
		 * 「开启/关闭/重涂」三态按钮与安全确认框已删；放行由 install/update/doctor
		 * 无条件重涂完成，状态实况在 status 的 web_remote_state 里可查 */

		/* 端口全自动（§25）：每次启动由 web-run.sh 在 3081-3099 现选空闲口，页面
		 * 不设端口输入框（曾有的「监听端口/应用端口」已删——自动选端口是治本，
		 * 固定口被占恰是启动失败头因；手工 UCI 配 openwrt-dsh.web.port 的通道保留）。
		 * 实际生效端口以状态行 web_url（启动行）为唯一真源 */

		/* 软件包自更新区：状态行复用 statusRow（随 2s 轮询刷新），按钮走独立 rpc */
		var updTable = E('table', { 'class': 'table' }, [
			this.statusRow('pkg_version', _('当前包版本')),
			this.statusRow('gh_latest', _('GitHub 最新发布'))
		]);

		/* 上传安装按钮（排在「检查更新」左边）：点它选 ipk，或把 ipk 直接拖到按钮上。
		 * 拖放用原生 dragover/drop 事件——dragover 必须 preventDefault 才允许 drop；
		 * 高亮类提醒「可以放了」。文件类型/大小校验在 handleUploadPicked（选框与拖放
		 * 共用同一条路），按钮只负责把文件递过去 */
		this.btnUploadInstall = E('button', {
			'class': 'btn cbi-button-action',
			'title': _('选择本机 ipk 上传安装（也可直接把 ipk 拖到这个按钮上）'),
			'click': ui.createHandlerFn(this, 'handleUploadClick'),
			'dragover': function(ev) {
				var types = ev.dataTransfer ? ev.dataTransfer.types : null;
				if (!types || Array.prototype.indexOf.call(types, 'Files') < 0) { return; }
				ev.preventDefault();
				ev.dataTransfer.dropEffect = 'copy';
				this.classList.add('odw-dropok');
			},
			'dragleave': function() { this.classList.remove('odw-dropok'); },
			'drop': function(ev) {
				this.classList.remove('odw-dropok');
				if (!ev.dataTransfer || !ev.dataTransfer.files || !ev.dataTransfer.files.length) { return; }
				ev.preventDefault();
				self.handleUploadPicked(ev.dataTransfer.files[0]);
			}
		}, _('上传安装'));
		this.ipkInput = E('input', {
			'type': 'file',
			'accept': '.ipk',
			'style': 'display:none',
			/* 选完清 value：同名文件再选一次也能触发 change（不清的话浏览器不重复触发） */
			'change': function(ev) {
				var f = (ev.target.files && ev.target.files.length) ? ev.target.files[0] : null;
				ev.target.value = '';
				self.handleUploadPicked(f);
			}
		});

		this.btnCheck = E('button', {
			'class': 'btn cbi-button-action',
			'title': _('查询 GitHub 上的最新发布（只读，不改动系统）'),
			'click': ui.createHandlerFn(this, 'handleCheckUpdate')
		}, _('检查更新'));

		this.btnSelfupdate = E('button', {
			'class': 'btn cbi-button-positive important',
			'title': _('下载 GitHub 最新 ipk 并用 opkg 安装升级'),
			'disabled': '',
			'click': ui.createHandlerFn(this, 'handleSelfupdate')
		}, _('立即更新'));

		this.dirInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': '/opt/openwrt-dsh', 'style': 'flex:1 1 auto; min-width:220px' });
		this.btnBrowse = E('button', {
			'class': 'btn cbi-button',
			'click': ui.createHandlerFn(this, 'handleBrowse')
		}, _('浏览…'));
		/* 迁移按钮：与「浏览」并排在安装目录右侧。只有已安装（dsh 版本读到）时才可点
		 * ——迁移搬的是已装内容，没装就无物可搬；状态没读到前与未装时都置灰 */
		this.btnMigrate = E('button', {
			'class': 'btn cbi-button',
			'title': _('正在读取状态…'),
			'disabled': '',
			'click': ui.createHandlerFn(this, 'handleMigrate')
		}, _('迁移'));
		var dirControl = E('div', { 'style': 'display:flex; gap:6px; align-items:center; width:100%' }, [ this.dirInput, this.btnBrowse, this.btnMigrate ]);
		this.regInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'https://registry.npmmirror.com' });
		this.repoInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'StormDAmon/openwrt-dsh' });
		this.proxyInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'https://ghfast.top（前缀形态，留空直连）' });

		/* 设置初值(uci.load 已在 load() 完成) + 状态轮询挂载 */
		this.dirInput.value = uci.get('openwrt-dsh', 'core', 'install_dir') || '/opt/openwrt-dsh';
		this.regInput.value = uci.get('openwrt-dsh', 'core', 'npm_registry') || '';
		this.repoInput.value = uci.get('openwrt-dsh', 'core', 'github_repo') || 'StormDAmon/openwrt-dsh';
		this.proxyInput.value = uci.get('openwrt-dsh', 'core', 'github_proxy') || '';

		poll.add(L.bind(function() {
			return callStatus().then(L.bind(function(st) {
				self.applyStatus(st);
			}, self)).catch(L.bind(function() {
				/* rpc 请求层失败(HTTP 错误/超时)也落到同一条横幅——之前会静默卡死,
				 * 按钮永远灰着且无任何提示,用户只能对着「检查中」发呆 */
				self.applyStatus(null);
			}, this));
		}, this), 2);

		return E([
			banner,
			/* 拖放高亮样式：虚线框提示「松手即可装这个包」 */
			E('style', { 'type': 'text/css' },
				'.odw-dropok{outline:2px dashed #2e7ed6; outline-offset:1px}'),
			E('h2', {}, [ _('DeepSeek Harness 管理'), this.verBadge ]),
			E('div', { 'class': 'cbi-map-descr' }, _(
				'在 OpenWrt/iStoreOS 上安装、更新与卸载 dsh。引擎自动处理 musl 机全链路：' +
				'Node unofficial musl 构建、Alpine 运行库三件套、加载器垫片与 ELF 补丁、' +
				'koffi/node-pty 原生件修复。任务会弹出「执行过程」窗口实时滚动日志（收起不影响' +
				'后台任务，任务进行中可点状态区「查看执行过程」重开）。')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('状态')),
				statusTable,
				E('div', { 'class': 'cbi-page-actions' }, [
					this.btnTask,
					E('span', {}, ' '),
					this.btnDoctor,
					E('span', {}, ' '),
					this.btnUninstall,
					E('span', {}, ' '),
					this.btnWatch
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Web 界面（dsh web）')),
				E('div', { 'class': 'cbi-map-descr' }, _(
					'把路由器当 dsh Web 主机：局域网设备用浏览器即可打开 dsh 界面。默认关闭；' +
					'开启后 dsh 监听所有网卡，首次访问必须用下方带令牌的访问链接（令牌随服务' +
					'每次启动更换，无令牌一律 401）。请勿把该端口转发/映射到外网——拿到链接的' +
					'人能通过 AI 在路由器上执行操作，只在可信局域网开启。局域网 IP 打开的页面' +
					'默认不能改 dsh 设置（上游安全边界）；本插件安装时已自动给 dsh 打补丁放行' +
					'局域网的设置读写（「设置→模型」等直接可用）。')),
				webTable,
				E('div', { 'class': 'cbi-page-actions' }, [
					this.btnWebToggle,
					E('span', {}, ' '),
					this.btnOpen
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('软件包更新')),
				E('div', { 'class': 'cbi-map-descr' }, _(
					'更新 openwrt-dsh 插件自身：「检查更新/立即更新」查 GitHub Releases 最新 tag → ' +
					'下载 ipk → sha256 校验 → opkg 安装；「上传安装」把本机已下载好的 ipk 直接传上去装' +
					'（升级/降级/重装均可，适合离线或开发场景，也可把 ipk 拖到「上传安装」按钮上）。' +
					'两者只替换插件文件，不影响已装的 dsh 与运行时。CN 网络直连 GitHub 常不通，' +
					'可在下方「设置」里配置加速代理。')),
				updTable,
				E('div', { 'class': 'cbi-page-actions' }, [
					this.btnUploadInstall,
					this.ipkInput,
					E('span', {}, ' '),
					this.btnCheck,
					E('span', {}, ' '),
					this.btnSelfupdate
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('设置')),
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left', 'width': '33%' }, _('安装目录')),
						E('td', { 'class': 'td left' }, [ dirControl ])
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left' }, _('npm 源')),
						E('td', { 'class': 'td left' }, [ this.regInput ])
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left' }, _('GitHub 仓库')),
						E('td', { 'class': 'td left' }, [ this.repoInput ])
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left' }, _('GitHub 加速代理')),
						E('td', { 'class': 'td left' }, [ this.proxyInput ])
					])
				]),
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'btn cbi-button-action',
						'click': ui.createHandlerFn(this, 'handleSaveConfig')
					}, _('保存设置'))
				])
			])
		]);
	},

	addBanner: function(text, kind) {
		var b = document.getElementById('odw-banner');
		b.className = 'alert-message ' + (kind || 'warning');
		b.textContent = text;
	},

	applyStatus: function(st) {
		if (!st || !st.arch) {
			/* 注意措辞：ubus 出错在 LuCI rpc 层会被吞成空对象(resolve 而非 reject)，
			 * 对象未注册/权限拒绝/后端崩溃在这里长得一模一样。装包后 rpcd 没重载是
			 * 最常见成因——「重装包」救不了它(重装不触发 reload)，所以把真正的
			 * 补救动作写进文案(r5 起包自带 postinst reload，正常安装不会再遇到)。 */
			this.addBanner(_('rpcd 后端不可用（luci.openwrt-dsh）。若刚安装/升级过本包，请 SSH 执行 /etc/init.d/rpcd reload（或重启路由器）后强制刷新页面（Ctrl+F5）；多次重装无效时再重装 openwrt-dsh 包。'), 'error');
			return;
		}

		this.cells['platform'].textContent = st.arch + ' / ' + st.libc + (st.distro ? '（' + st.distro + '）' : '');
		this.cells['install_dir'].textContent = st.install_dir || '';
		this.cells['free'].textContent = st.free ? fmtBytes(st.free) : '?';
		this.cells['node_version'].textContent = st.node_version || _('未安装');

		/* dsh 版本行带检查标记：检查缓存（「更新 dsh」前置检查落盘）说有新版、且本机
		 * 版本确实落后于缓存 latest（verGe 挡住「装完新版但缓存还没重查」的过期显示）
		 * 才标「可更新到 X」；本机已追平/超过就标「已是最新」。没检查过则只显示版本 */
		var dshTxt = st.dsh_version || _('未安装');
		if (st.dsh_version && st.dsh_latest) {
			var dshBase = String(st.dsh_version).replace(/^v/, '');
			if (verGe(dshBase, st.dsh_latest)) {
				dshTxt += '（' + _('已是最新') + '）';
			} else if (st.dsh_available == 'yes') {
				dshTxt += '（' + _('可更新到 %s').format(st.dsh_latest) + '）';
			}
		}
		this.cells['dsh_version'].textContent = dshTxt;
		this.cells['registry'].textContent = st.registry || 'npm 官方';

		var phase = st.task_phase || 'idle';
		var task = st.task_name || '';
		var phaseText;
		if (phase == 'running') {
			phaseText = _('进行中') + '（' + task + '）';
		} else if (phase == 'done') {
			phaseText = _('上次任务成功') + '（' + task + '）';
		} else if (phase == 'failed') {
			phaseText = _('上次任务失败') + '（' + task + '，退出码 ' + (st.task_rc || '?') + '）';
		} else {
			phaseText = _('空闲');
		}
		this.cells['task'].textContent = phaseText;

		this.lastDsh = st.dsh_version || '';
		this.lastInstallDir = st.install_dir || '';
		this.taskRunning = (phase == 'running');
		/* 「查看执行过程」按钮的目标标题：按任务名映射成人话（未知任务名原样展示） */
		var taskTitles = {
			install: _('安装 dsh'), update: _('更新 dsh'), doctor: _('校验修复（doctor）'),
			uninstall: _('卸载 dsh'), selfupdate: _('软件包自更新'), migrate: _('迁移安装目录'),
			localinstall: _('上传安装')
		};
		this.lastTaskTitle = taskTitles[task] || task;
		this.btnTask.textContent = this.lastDsh
			? (phase == 'running' ? _('任务进行中…') : _('更新 dsh'))
			: (phase == 'running' ? _('任务进行中…') : _('安装 dsh'));
		/* title 跟随分化后的按钮语义（render 期占位的「正在读取状态…」只该存在于
		 * 状态未读到的那几秒）；更新是先检查后确认，title 里写清这个行为 */
		this.btnTask.title = this.lastDsh
			? _('先检查 npm 源最新版，确认有新版后再确认更新')
			: _('安装最新版 dsh');
		this.btnTask.disabled = this.taskRunning;
		this.btnDoctor.disabled = this.taskRunning;
		/* 卸载只在「有东西可卸且没有任务在跑」时可用；平台不受支持不拦卸载（rm 不挑平台） */
		this.btnUninstall.disabled = this.taskRunning || !this.lastDsh;
		this.btnSelfupdate.disabled = this.taskRunning;
		/* 上传安装同门槛：opkg 任务互斥，任务跑着时不收新包（点了/拖了也会被 handleUploadPicked 拦） */
		this.btnUploadInstall.disabled = this.taskRunning;
		/* 执行过程窗口的重开入口只该在任务跑着时出现（结束后看结果靠窗口终局行与状态表） */
		this.btnWatch.style.display = this.taskRunning ? '' : 'none';
		/* 迁移同卸载的门槛：只在「已安装且没有任务在跑」时可点 */
		this.btnMigrate.disabled = this.taskRunning || !this.lastDsh;
		this.btnMigrate.title = this.lastDsh
			? _('把已安装的 dsh 与 Node 运行时整体搬到别的目录（如数据盘）')
			: _('尚未安装 dsh，无需迁移');

		/* 迁移成功后把设置里的安装目录输入框同步成新值：输入框还停在旧路径的话，
		 * 用户随手「保存设置」会把刚迁好的 UCI 改回旧路径（下次安装又装回去） */
		if (st.task_name == 'migrate' && phase == 'done' &&
		    this.lastInstallDir && this.dirInput.value != this.lastInstallDir) {
			this.dirInput.value = this.lastInstallDir;
		}

		/* 上传安装的收尾提示（本页没有日志区，用户只能盯着「任务状态」行；装完不刷新
		 * 会一直跑旧版界面 JS——视图文件名随版本变，刷新才拉新版，§20 的缓存机制）。
		 * 用 localInstallTip 标记只提示一次；重新发起上传时在 doUploadInstall 里复位 */
		if (st.task_name == 'localinstall' && !this.taskRunning && !this.localInstallTip) {
			this.localInstallTip = true;
			if (phase == 'done') {
				ui.addNotification(null, E('p', {}, _('上传安装完成，请刷新浏览器页面（Ctrl+F5）加载新界面。')), 'success');
			} else if (phase == 'failed') {
				ui.addNotification(null, E('p', {}, _('上传安装失败（退出码 %s），日志明细可 SSH 执行 openwrt-dsh log 查看；上传的包已保留，修正后可重试。').format(st.task_rc || '?')), 'error');
			}
		}

		/* 软件包版本与 GitHub 检查结果（来自 status 快照：包版本读 opkg 库缓存，检查结果读
		 * 「检查更新」落盘的缓存——本路径绝不联网，没检查过就显示未检查） */
		this.cells['pkg_version'].textContent = st.pkg_version || _('未安装/未知');
		this.verBadge.textContent = st.pkg_version ? 'v' + st.pkg_version : '';
		this.lastGh = st.gh_latest || '';
		var ghTxt;
		if (st.gh_latest) {
			ghTxt = st.gh_latest;
			if (st.gh_check_ts) {
				ghTxt += '（' + new Date(parseInt(st.gh_check_ts, 10) * 1000).toLocaleTimeString() + '）';
			}
			if (st.gh_available == 'yes') {
				ghTxt += ' · ' + _('可更新');
			}
		} else if (st.gh_check_status == 'error') {
			ghTxt = _('检查失败');
			if (st.gh_check_ts) {
				ghTxt += '（' + new Date(parseInt(st.gh_check_ts, 10) * 1000).toLocaleTimeString() + '）';
			}
		} else {
			ghTxt = _('未检查');
		}
		this.cells['gh_latest'].textContent = ghTxt;

		/* —— Web 界面（dsh web 服务）区：随轮询刷新开关文案、状态行与「打开」按钮 ——
		 * 「打开」地址的取法（优先级即顺序）：
		 * 1) 浏览器当前用 IP 字面量访问 LuCI（绝大多数场景）：同一个 IP + 服务端口 +
		 *    令牌拼链接。该 IP 就是用户可达的那个接口，且 IP 字面量 Host 必过 dsh 的
		 *    浏览器信任栅栏（栅栏只认回环与部署派生的 LAN IP 字面量，域名一律拒——
		 *    DNS rebinding 防线，用域名开过去界面能加载但 /api 全 401）。
		 * 2) 后端启动行里的 LAN 链接（dsh 绑 0.0.0.0 时自动携带第一个非回环 IPv4）。
		 * 3) 都没有（只有回环链接）→ 没有可打开的地址：回环地址在用户 PC 上指向用户
		 *    自己的电脑，给出来只会误导，按钮置灰。 */
		this.webEnabled = (st.web_enabled == '1');
		this.webRunning = (st.web_running == '1');
		/* 配置语义端口（页面已无端口输入框，仅作 openUrl 的兜底）：后端已把
		 * 空/非法/旧固定 3080 归一为空（= 自动，§25）。实际生效端口另从启动行
		 * URL 解析——自动模式下每次启动都可能不同，web_url 是唯一真源，绝不能
		 * 拿配置口拼访问链接 */
		this.webPort = st.web_port || '';
		var webRawUrl = st.web_url || '';
		var webRunPort = (/http:\/\/[^\/]*:(\d+)\//.exec(webRawUrl) || [])[1] || '';
		var webToken = (/[?&]token=([^&]+)/.exec(webRawUrl) || [])[1] || '';
		var webHost = window.location.hostname || '';
		var webHostIsIp = /^\d{1,3}(\.\d{1,3}){3}$/.test(webHost);
		this.openUrl = '';
		if (webToken && webHostIsIp) {
			this.openUrl = 'http://' + webHost + ':' + (webRunPort || this.webPort) + '/?token=' + webToken;
		} else if (webRawUrl && webRawUrl.indexOf('127.0.0.1') < 0 && webRawUrl.indexOf('localhost') < 0) {
			this.openUrl = webRawUrl;
		}

		var webTxt;
		/* 优先级：错误 > 运行中 > 已启用未运行 > 未启用。web_error 排在 webRunning
		 * 之前是 2026-10-20 的实锤要求：procd respawn 放弃后 instance 永久留在注册表
		 * （running:false 不注销），崩溃循环期 web_running 恒为 1，若先看 running
		 * 会把「起不来」永远盖成「正在生成访问链接」 */
		if (!this.lastDsh) {
			webTxt = _('未安装 dsh');
		} else if (this.webEnabled && st.web_error) {
			/* 启动失败原因直接亮在状态行（后端从 web-run.sh 的 out.log 提取，端口被占
			 * 等崩溃一目了然）——此前只会说「看系统日志」，用户在 LuCI 里根本无门而入 */
			webTxt = _('已启用，但未运行') + '：' + st.web_error;
		} else if (this.webRunning) {
			webTxt = this.openUrl ? _('运行中') : _('运行中（正在生成访问链接…）');
		} else if (this.webEnabled) {
			webTxt = _('已启用，但服务未运行（看系统日志 openwrt-dsh-web）');
		} else {
			webTxt = _('未启用');
		}
		var webCell = this.cells['web_state'];
		webCell.textContent = webTxt;
		/* 失败原因在场时整条标红，扫一眼就知道不是「还在启动」而是「起不来」 */
		webCell.style.color = (this.webEnabled && st.web_error) ? '#c5221f' : '';
		webCell.title = webTxt;
		this.cells['web_url'].textContent = (this.webRunning && this.openUrl) ? this.openUrl : '—';

		this.btnWebToggle.textContent = this.webEnabled ? _('停用 Web 服务') : _('启用 Web 服务');
		this.btnWebToggle.disabled = this.taskRunning || !this.lastDsh;
		this.btnWebToggle.title = !this.lastDsh
			? _('尚未安装 dsh，无可开启的 Web 服务')
			: (this.webEnabled
				? _('停止 dsh Web 服务并取消开机自启')
				: _('开启后局域网设备可打开 dsh Web 界面（首次访问需带令牌链接）'));

		/* 「打开」按钮：已安装才显示（需求口径）；运行且拿到链接才可点 */
		this.btnOpen.style.display = this.lastDsh ? '' : 'none';
		this.btnOpen.disabled = !(this.webRunning && this.openUrl);
		this.btnOpen.title = this.openUrl
			? _('在新标签页打开 dsh Web 界面（%s）').format(this.openUrl)
			: _('服务未运行或访问链接未就绪');

		if (st.supported != 'yes') {
			this.addBanner(_('当前平台不受支持（仅 Linux x86_64 musl；ARM 路由器见项目 roadmap）。'), 'error');
			this.btnTask.disabled = true;
			this.btnMigrate.disabled = true;
		} else if (parseInt(st.free, 10) > 0 && parseInt(st.free, 10) < 314572800) {
			/* 分区吃紧：没装的建议换目录再装；已装的正好用「迁移」搬到数据盘 */
			if (st.node_version) {
				this.addBanner(_('安装目录所在分区可用空间不足 300MB，可点安装目录旁的「迁移」把已装内容搬到数据盘。'), 'warning');
			} else {
				this.addBanner(_('安装目录所在分区可用空间不足 300MB，建议在下方设置里改到数据盘。'), 'warning');
			}
		}
	},

	load: function() {
		return uci.load('openwrt-dsh');
	}
});
