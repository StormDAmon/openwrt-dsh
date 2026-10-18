// PT_INTERP / DT_NEEDED 双补丁器（openwrt-dsh 引擎件）
// 用法: node elf-patch.js <待补二进制> <新interp路径> <libgcc新路径> <输出文件>
// 场景: 老 musl 加载器（OpenWrt 22.03 = musl 1.2.3）拉不动 musl 版 node 真身时，把真身
// 改造成「零系统耦合」——interp 指向自带的 ld-musl（加载器即 libc，配自带 libstdc++ 直拉
// 自洽），DT_NEEDED libgcc_s.so.1 改指自带 libgcc 的短路径（$HOME/.s/g）。
// libgcc 必须走补丁而非环境变量：老 musl 系统的动态 busybox 子进程（sed/env/sh -c/npm 链）
// 从 LD_LIBRARY_PATH 撞见新版 libgcc_s 会 10/10 段错误（只 libstdc++ 无害 0/10，实测）。
// 约束与安全：
//   - 仅处理小端 ELF64 且 interp 含 ld-musl 的文件（glibc 构建不动）；两处改写都在原段
//     长度预算内原地覆盖（p_filesz / 字符串原长），放不下就明确放弃该项，不越界；
//   - 补丁写新文件（out），由调用方探测通过后原子顶替，本脚本失败/放弃都不损伤原文件；
//   - 幂等：已补丁的文件再次执行，内容相同（interp === 新路径时按已处理）。
const fs = require("fs");
const bin = process.argv[2], interp = process.argv[3], gneed = process.argv[4], out = process.argv[5];
const b = fs.readFileSync(bin);
if (b[0] !== 127 || b.toString("ascii", 1, 4) !== "ELF" || b[4] !== 2 || b[5] !== 1) { console.error("不是小端 ELF64:" + bin); process.exit(1); }
const phoff = Number(b.readBigUInt64LE(32)), phes = b.readUInt16LE(54), phn = b.readUInt16LE(56);
const loads = [];
let dynOff = 0, dynSz = 0, ip = null;
for (let i = 0; i < phn; i++) {
    const o = phoff + i * phes, t = b.readUInt32LE(o);
    if (t === 1) loads.push({ off: Number(b.readBigUInt64LE(o + 8)), va: Number(b.readBigUInt64LE(o + 16)), sz: Number(b.readBigUInt64LE(o + 32)) });
    else if (t === 2) { dynOff = Number(b.readBigUInt64LE(o + 8)); dynSz = Number(b.readBigUInt64LE(o + 32)); }
    else if (t === 3 && !ip) ip = { off: Number(b.readBigUInt64LE(o + 8)), sz: Number(b.readBigUInt64LE(o + 32)) };
}
const v2o = (va) => { for (const s of loads) if (va >= s.va && va < s.va + s.sz) return va - s.va + s.off; return -1; };
const did = [];
if (ip) {
    let e = b.indexOf(0, ip.off);
    if (e < 0 || e > ip.off + ip.sz) e = ip.off + ip.sz;
    const cur = b.toString("ascii", ip.off, e);
    if (cur.indexOf("ld-musl") >= 0 || cur === interp) {
        if (Buffer.byteLength(interp, "ascii") + 1 <= ip.sz) { b.fill(0, ip.off, ip.off + ip.sz); b.write(interp, ip.off, "ascii"); did.push("interp " + cur + " -> " + interp); }
        else did.push("interp 段放不下新路径,未改(" + cur + ")");
    } else did.push("interp 非 musl 加载器,未改(" + cur + ")");
} else did.push("无 PT_INTERP,interp 未改");
if (dynOff && gneed) {
    let strVa = 0;
    const offs = [];
    for (let o = dynOff; o < dynOff + dynSz; o += 16) {
        const tag = Number(b.readBigUInt64LE(o));
        if (tag === 5) strVa = Number(b.readBigUInt64LE(o + 8));
        else if (tag === 1) offs.push(Number(b.readBigUInt64LE(o + 8)));
    }
    const so = v2o(strVa);
    if (so < 0) did.push("DT_STRTAB 定位失败,libgcc 未改");
    else {
        let n = 0, skip = 0;
        for (const off of offs) {
            const st = so + off, e = b.indexOf(0, st);
            const cur = b.toString("ascii", st, e);
            if (cur === "libgcc_s.so.1" && cur !== gneed) {
                if (Buffer.byteLength(gneed, "ascii") + 1 <= cur.length + 1) { b.fill(0, st, e); b.write(gneed, st, "ascii"); n++; }
                else skip++;
            }
        }
        if (n) did.push("DT_NEEDED libgcc_s.so.1 -> " + gneed + "(" + n + " 处)");
        else if (skip) did.push("libgcc 新路径超长,未改(跳过 " + skip + " 处)");
        else did.push("无 libgcc_s.so.1 NEEDED,未改");
    }
} else did.push("无 PT_DYNAMIC,libgcc 未改");
fs.writeFileSync(out, b);
console.log("补丁:" + did.join("; "));
