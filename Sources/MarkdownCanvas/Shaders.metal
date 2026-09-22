#include <metal_stdlib>
using namespace metal;

// 40 字节，与 Swift 侧 DrawInstance 一一对应
struct Instance {
    float2 position;    // 文档坐标 pt，quad 左上角
    float2 size;        // pt
    float2 uvOrigin;
    float2 uvSize;
    uchar4 color;       // straight alpha
    short  textureIndex;
    ushort flags;
};

struct Uniforms {
    float2 viewportSize;   // drawable 像素
    float2 scrollOffset;   // 逻辑 pt
    float  scale;          // 像素 / pt
    float  _pad;
    float2 atlasSize;      // 字形图集纹素尺寸
};

struct VOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

// 单一顶点函数：vertex_id 生成 quad 四角，instance_id 取实例。
// 文档坐标 → 减滚动偏移 → 乘 scale → snap 到整数像素 → NDC（y 翻转：
// Metal NDC y 向上，而文档/视图坐标 y 向下）。
//
// ⚠️ 顶点顺序必须是 Z 字形：(0,0) (1,0) (0,1) (1,1)。
// 曾误用绕圈序 (0,0)(1,0)(1,1)(0,1)（triangle list 的顺序）——strip 的
// 两个三角形 (v0,v1,v2)+(v1,v2,v3) 因此只覆盖 {x≥y}∪{x+y≥1}，
// 每个 quad 的左上三角永远缺失（每个字形被对角线切掉一半）。
//
// 🔬 清晰度：字形 quad 两个角 snap 到整数像素，且 quad 像素尺寸 = 栅格
// 纹素数（uvSize，CPU 侧已把 position 内缩 pad/scale），fragment 中心
// 恰好落在纹素中心 —— linear 采样退化为精确取值，输出 = 栅格位图原样
// （保留 CTFontDrawGlyphs 的 1px AA 边）。不做这一步时，分数像素位置上
// 的 linear 重采样会把 1px 过渡带拉宽到 ~2px（实测软像素 64% → 46%，
// 达到 CoreText 直接绘制的水平）。solid 矩形同样受益于 snap
// （下划线/边框获得精确像素边界）。
vertex VOut quad_vertex(uint vid [[vertex_id]],
                        uint iid [[instance_id]],
                        constant Uniforms &u [[buffer(0)]],
                        const device Instance *instances [[buffer(1)]]) {
    Instance in = instances[iid];
    // Z 字形四角：vid 0=(0,0) 1=(1,0) 2=(0,1) 3=(1,1)
    float2 c = float2(vid == 1 || vid == 3 ? 1.0 : 0.0, vid >= 2 ? 1.0 : 0.0);

    float2 px0 = (in.position - u.scrollOffset) * u.scale;
    float2 px1 = px0 + in.size * u.scale;
    float2 s0 = floor(px0 + 0.5);          // 角点 snap 到整数像素
    float2 s1 = floor(px1 + 0.5);
    if (in.textureIndex == 0) {
        s1 = s0 + in.uvSize;               // 字形：quad = 完整栅格（纹素数）
    }
    float2 p = mix(s0, s1, c);
    float2 ndc = p / u.viewportSize * 2.0 - 1.0;
    ndc.y = -ndc.y;

    VOut o;
    o.position = float4(ndc, 0.0, 1.0);
    if (in.textureIndex >= 1) {
        o.uv = in.uvOrigin + c * in.uvSize;              // 图片：归一化 UV
    } else {
        o.uv = (in.uvOrigin + (p - s0)) / u.atlasSize;   // 字形：像素中心 = 纹素中心
    }
    o.color = float4(in.color) / 255.0;
    return o;
}

// 字形：图集 R 通道即 alpha
fragment float4 glyph_fragment(VOut in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
    float a = atlas.sample(smp, in.uv).r;
    return float4(in.color.rgb, in.color.a * a);
}

// 纯色块：下划线 / 删除线 / 引用竖线 / 表格边框 / 代码底色 / HR
fragment float4 solid_fragment(VOut in [[stage_in]]) {
    return in.color;
}
