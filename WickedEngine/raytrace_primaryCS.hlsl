#include "globals.hlsli"
#include "ShaderInterop_TracedRendering.h"
#include "tracedRenderingHF.hlsli"


RWRAWBUFFER(counterBuffer_WRITE, 0);
RWSTRUCTUREDBUFFER(rayBuffer_WRITE, StoredRay, 1);
RWTEXTURE2D(resultTexture, float4, 2);

struct Material
{
	float4		baseColor;
	float4		texMulAdd;
	float		roughness;
	float		reflectance;
	float		metalness;
	float		emissive;
	float		refractionIndex;
	float		subsurfaceScattering;
	float		normalMapStrength;
	float		parallaxOcclusionMapping;
};
STRUCTUREDBUFFER(materialBuffer, Material, TEXSLOT_ONDEMAND0);
TYPEDBUFFER(meshIndexBuffer, uint, TEXSLOT_ONDEMAND1);
RAWBUFFER(meshVertexBuffer_POS, TEXSLOT_ONDEMAND2);
TYPEDBUFFER(meshVertexBuffer_TEX, float2, TEXSLOT_ONDEMAND3);

TEXTURE2D(texture_baseColor, float4, TEXSLOT_ONDEMAND4);
TEXTURE2D(texture_normalMap, float4, TEXSLOT_ONDEMAND5);
TEXTURE2D(texture_surfaceMap, float4, TEXSLOT_ONDEMAND6);

RAWBUFFER(counterBuffer_READ, TEXSLOT_ONDEMAND8);
STRUCTUREDBUFFER(rayBuffer_READ, StoredRay, TEXSLOT_ONDEMAND9);

inline RayHit TraceScene(Ray ray)
{
	RayHit bestHit = CreateRayHit();

	for (uint tri = 0; tri < xTraceMeshTriangleCount; ++tri)
	{
		// load indices of triangle from index buffer
		uint i0 = meshIndexBuffer[tri * 3 + 0];
		uint i1 = meshIndexBuffer[tri * 3 + 2];
		uint i2 = meshIndexBuffer[tri * 3 + 1];

		// load vertices of triangle from vertex buffer:
		float4 pos_nor0 = asfloat(meshVertexBuffer_POS.Load4(i0 * xTraceMeshVertexPOSStride));
		float4 pos_nor1 = asfloat(meshVertexBuffer_POS.Load4(i1 * xTraceMeshVertexPOSStride));
		float4 pos_nor2 = asfloat(meshVertexBuffer_POS.Load4(i2 * xTraceMeshVertexPOSStride));

		uint nor_u = asuint(pos_nor0.w);
		uint materialIndex;
		float3 nor0;
		{
			nor0.x = (float)((nor_u >> 0) & 0x000000FF) / 255.0f * 2.0f - 1.0f;
			nor0.y = (float)((nor_u >> 8) & 0x000000FF) / 255.0f * 2.0f - 1.0f;
			nor0.z = (float)((nor_u >> 16) & 0x000000FF) / 255.0f * 2.0f - 1.0f;
			materialIndex = (nor_u >> 28) & 0x0000000F;
		}
		nor_u = asuint(pos_nor1.w);
		float3 nor1;
		{
			nor1.x = (float)((nor_u >> 0) & 0x000000FF) / 255.0f * 2.0f - 1.0f;
			nor1.y = (float)((nor_u >> 8) & 0x000000FF) / 255.0f * 2.0f - 1.0f;
			nor1.z = (float)((nor_u >> 16) & 0x000000FF) / 255.0f * 2.0f - 1.0f;
		}
		nor_u = asuint(pos_nor2.w);
		float3 nor2;
		{
			nor2.x = (float)((nor_u >> 0) & 0x000000FF) / 255.0f * 2.0f - 1.0f;
			nor2.y = (float)((nor_u >> 8) & 0x000000FF) / 255.0f * 2.0f - 1.0f;
			nor2.z = (float)((nor_u >> 16) & 0x000000FF) / 255.0f * 2.0f - 1.0f;
		}

		Triangle prim;
		prim.v0 = pos_nor0.xyz;
		prim.v1 = pos_nor1.xyz;
		prim.v2 = pos_nor2.xyz;
		prim.n0 = nor0;
		prim.n1 = nor1;
		prim.n2 = nor2;
		prim.t0 = meshVertexBuffer_TEX[i0];
		prim.t1 = meshVertexBuffer_TEX[i1];
		prim.t2 = meshVertexBuffer_TEX[i2];
		prim.materialIndex = materialIndex;

		IntersectTriangle(ray, bestHit, prim);
	}


	return bestHit;
}

inline float3 Shade(inout Ray ray, RayHit hit, inout float seed, in float2 pixel)
{
	if (hit.distance < INFINITE_RAYHIT)
	{
		float4 baseColorMap = texture_baseColor.SampleLevel(sampler_linear_wrap, hit.texCoords, 0);
		float4 normalMap = texture_normalMap.SampleLevel(sampler_linear_wrap, hit.texCoords, 0);
		float4 surfaceMap = texture_surfaceMap.SampleLevel(sampler_linear_wrap, hit.texCoords, 0);

		Material mat = materialBuffer[hit.materialIndex];
		
		float4 baseColor = mat.baseColor * baseColorMap;
		float reflectance = mat.reflectance/* * surfaceMap.r*/;
		float metalness = mat.metalness/* * surfaceMap.g*/;
		float3 emissive = baseColor.rgb * mat.emissive * surfaceMap.b;
		float roughness = mat.roughness/* * normalMap.a*/;

		float3 albedo = ComputeAlbedo(baseColor, reflectance, metalness);
		float3 specular = ComputeF0(baseColor, reflectance, metalness);


		// Calculate chances of diffuse and specular reflection
		albedo = min(1.0f - specular, albedo);
		float specChance = dot(specular, 0.33);
		float diffChance = dot(albedo, 0.33);
		float inv = 1.0f / (specChance + diffChance);
		specChance *= inv;
		diffChance *= inv;

		// Roulette-select the ray's path
		float roulette = rand(seed, pixel);
		if (roulette < specChance)
		{
			// Specular reflection
			//float alpha = 150.0f;
			float alpha = sqr(1 - roughness) * 1000;
			ray.origin = hit.position + hit.normal * EPSILON;
			ray.direction = SampleHemisphere(reflect(ray.direction, hit.normal), alpha, seed, pixel);
			float f = (alpha + 2) / (alpha + 1);
			ray.energy *= (1.0f / specChance) * specular * saturate(dot(hit.normal, ray.direction) * f);
		}
		else
		{
			// Diffuse reflection
			ray.origin = hit.position + hit.normal * EPSILON;
			ray.direction = SampleHemisphere(hit.normal, 1.0f, seed, pixel);
			ray.energy *= (1.0f / diffChance) * albedo;
		}

		return emissive;
	}
	else
	{
		// Erase the ray's energy - the sky doesn't reflect anything
		ray.energy = 0.0f;

		return GetDynamicSkyColor(ray.direction);
	}
}

[numthreads(TRACEDRENDERING_PRIMARY_GROUPSIZE, 1, 1)]
void main( uint3 DTid : SV_DispatchThreadID )
{
	if (DTid.x >= counterBuffer_READ.Load(0))
	{
		return;
	}

	// Load the current ray:
	Ray ray;
	uint pixelID;
	LoadRay(rayBuffer_READ[DTid.x], ray, pixelID);

	// Compute real pixel coords from flattened:
	uint2 coords2D = unflatten2D(pixelID, GetInternalResolution());

	// Compute screen coordinates:
	float2 uv = float2((coords2D + xTracePixelOffset) * g_xWorld_InternalResolution_Inverse * 2.0f - 1.0f) * float2(1, -1);

	float seed = g_xFrame_Time;

	RayHit hit = TraceScene(ray);
	float3 result = ray.energy * Shade(ray, hit, seed, uv);

	// Write the result:
	resultTexture[coords2D] += float4(result, 0);
	if (any(ray.energy))
	{
		uint prev;
		counterBuffer_WRITE.InterlockedAdd(0, 1, prev);
		rayBuffer_WRITE[prev] = CreateStoredRay(ray, pixelID);
	}
}
