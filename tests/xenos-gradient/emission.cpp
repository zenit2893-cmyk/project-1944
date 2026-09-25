#include "pch.h"
#include "shader_recompiler.h"
#include <fstream>
#include <stdexcept>

static unsigned checks = 0;
static void require(bool value, const char* message) {
    ++checks;
    if (!value) throw std::runtime_error(message);
}
static uint32_t destination(unsigned x, unsigned y, unsigned z, unsigned w) {
    return x | y << 3 | z << 6 | w << 9;
}
static std::string emit(TextureFetchInstruction instruction) {
    ShaderRecompiler recompiler;
    recompiler.isLegacyCoD3Container = true;
    recompiler.isPixelShader = true;
    recompiler.recompile(instruction, false);
    return recompiler.out;
}
int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("emission test requires output path");
        TextureFetchInstruction instruction{};
        instruction.opcode = FetchOpcode::GetTextureGradients;
        instruction.srcRegister = 1;
        instruction.dstRegister = 2;
        instruction.srcSwizzle = 2 | 0 << 2; // zx, not xy
        instruction.dstSwizzle = destination(3, 0, 5, 7); // W, X, one, preserve
        const auto get = emit(instruction);
        require(get == "r2.xy = getTextureGradientsCoD3(r1.zx).wx;\nr2.z = 1.0;\n", "getGradients swizzle/constant/mask");
        instruction.dstSwizzle = destination(4, 5, 7, 7);
        require(emit(instruction) == "r2.x = 0.0;\nr2.y = 1.0;\n", "getGradients constant-only destination");
        instruction.opcode = FetchOpcode::SetTextureGradientsHorz;
        instruction.srcSwizzle = 3 | 1 << 2 | 2 << 4;
        instruction.isPredicated = 1;
        instruction.predCondition = 0;
        const auto setH = emit(instruction);
        require(setH == "if (!p0)\n{\n\ttexGradH = r1.wyz;\n}\n", "set horizontal predication and xyz source");
        instruction.opcode = FetchOpcode::SetTextureGradientsVert;
        instruction.predCondition = 1;
        const auto setV = emit(instruction);
        require(setV == "if (p0)\n{\n\ttexGradV = r1.wyz;\n}\n", "set vertical predication and xyz source");
        instruction.srcRegisterAm = 1;
        require(emit(instruction).find("#error") != std::string::npos, "relative gradient must fail closed");
        instruction.srcRegisterAm = 0;
        instruction.opcode = FetchOpcode::TextureFetch;
        instruction.dimension = TextureDimension::TextureCube;
        instruction.useCompLod = 1;
        instruction.useRegGradients = 1;
        instruction.useRegLod = 1;
        instruction.lodBias = -8;
        instruction.constIndex = 19;
        instruction.dstSwizzle = destination(0,1,2,3);
        instruction.isPredicated = 0;
        const auto cube = emit(instruction);
        require(cube.find("tfetchCubeGradCoD3") != std::string::npos, "cube gradient lowering");
        require(cube.find("texGradH, texGradV, g_CoD3TextureFetchWord4[4].w, texLod + -0.5") != std::string::npos,
            "raw fetch slot and additive register/instruction LOD");
        instruction.dimension = TextureDimension::Texture2D;
        require(emit(instruction).find("tfetch2DGradCoD3") != std::string::npos, "2D gradient lowering");
        instruction.texCoordDenorm = 1;
        require(emit(instruction).find("#error") != std::string::npos, "unnormalized variant must fail closed");
        instruction.texCoordDenorm = 0;
        instruction.offsetX = 1;
        require(emit(instruction).find("#error") != std::string::npos, "offset variant must fail closed");
        instruction.offsetX = 0;
        instruction.useCompLod = 0;
        require(emit(instruction).find("#error") != std::string::npos, "unverified LOD mode must fail closed");
        instruction.useCompLod = 1;
        instruction.dimension = TextureDimension::Texture3D;
        require(emit(instruction).find("#error") != std::string::npos, "3D variant must fail closed");
        instruction.dimension = TextureDimension::Texture2D;
        instruction.mipFilter = 2;
        require(emit(instruction).find("#error") != std::string::npos, "base-map override must fail closed");
        ShaderRecompiler upstream;
        instruction.opcode = FetchOpcode::SetTextureGradientsHorz;
        upstream.recompile(instruction, false);
        require(upstream.out.empty(), "upstream path changed");
        std::ofstream fixtures(argv[1], std::ios::binary);
        fixtures << "float4 emittedGet(float4 p : SV_Position) : SV_Target {\n"
                    "float4 r1 = float4(5*p.x-7*p.y, 0, 2*p.x+3*p.y, 0);\n"
                    "float4 r2 = float4(-10,-20,-30,19);\n" << get << "return r2; }\n";
        fixtures << "float4 emittedSet(float4 p : SV_Position) : SV_Target {\n"
                    "float4 r1 = float4(11,13,17,19);\n"
                    "float3 texGradH = float3(23,29,31), texGradV = float3(37,41,43);\n"
                    "bool p0 = testMode != 0;\n" << setH << setV <<
                    "return float4(texGradH.x,texGradH.y,texGradV.y,texGradV.z); }\n";
        fixtures.close();
        std::printf("{\"emission_checks\":%u,\"passed\":true}\n", checks);
        return 0;
    } catch (const std::exception& exception) {
        std::fprintf(stderr,"%s\n",exception.what());
        return 1;
    }
}
