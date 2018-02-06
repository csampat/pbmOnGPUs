#include <vector>
#include <cmath>
#include <float.h>
#include <string>
#include <iostream>
#include <stdio.h>

#include "utility.cuh"
#include "parameterData.h"
#include "liggghtsData.h"

using namespace std;

#define TWOWAYCOUPLING false
#define NTHREADS 16
#define NBLOCKS 16

// MACROS 
// Calling macros for error check and dump data to files to VaribleName.txt

#define DUMP(varName) dumpData(varName, #varName)
#define DUMP2D(varName) dump2DData(varName, #varName)
#define DUMP3D(varName) dump3DData(varName, #varName)

#define DUMPCSV(varName) dumpCSV(varName, #varName)
#define DUMP2DCSV(varName) dump2DCSV(varName, #varName)
#define DUMP3DCSV(varName) dump3DCSV(varName, #varName)

#define DUMPDIACSV(time, dia) dumpDiaCSV(time, dia, #dia)

#define DUMP2DCSV4MATLAB(varName) dump2DCSV4Matlab(varName, #varName)

// extern __shared__ double *d_sMeshXY, *d_ssMeshXY;


__global__ void initialization_kernel(double *d_vs, double *d_vss, size_t size2D, double fsVolCoeff, double ssVolCoeff, double fsVolBase, double ssVolBase, double *d_sAgg, 
                                      double *d_ssAgg, int *d_sAggregationCheck, int *d_ssAggregationCheck, double *d_sLow, double *d_ssLow, double *d_sHigh, double *d_ssHigh, 
                                      double *d_sMeshXY, double *d_ssMeshXY, int *d_sLoc, int *d_ssLoc, int *d_sInd, int *d_ssInd, double *d_sBreak, double *d_ssBreak, 
                                      int *d_sLocBreak, int *d_ssLocBreak, int *d_sCheckB, int*d_ssCheckB, int  *d_sIndB, int *d_ssIndB)
{
    int idx = threadIdx.x;
    int bix = blockIdx.x;
    int bdx = blockDim.x;

    // __shared__ double d_sMeshXY[256], d_ssMeshXY[256];

    d_sMeshXY[bdx * bix + idx] = d_vs[bix];
    d_ssMeshXY[bdx * bix + idx] = d_vss[bix];
    d_sAgg[bdx * bix + idx] = d_vs[idx] + d_vs[bix];
    d_ssAgg[bdx * bix + idx] = d_vss[idx] + d_vss[bix];
    d_sAggregationCheck[bdx * bix + idx] = d_sAgg[bdx * bix + idx] <= d_vs[bdx - 1] ? 1 : 0;
    d_ssAggregationCheck[bdx * bix + idx] = d_ssAgg[bdx * bix + idx] <= d_vss[bdx - 1] ? 1 : 0;
    d_sLow [bdx * bix + idx] = d_sMeshXY[bdx * bix + idx];
    d_ssLow[bdx * bix + idx] = d_ssMeshXY[bdx * bix + idx];
    __syncthreads();
    if (bix < bdx -1)
    {
        d_sHigh[bdx * bix + idx] = d_sMeshXY[bdx * (bix + 1) + idx];
        d_ssHigh[bdx * bix + idx] = d_sMeshXY[bdx * (bix + 1) + idx];
    }
    d_sHigh[bdx * (bdx -1) + idx] = 0.0;
    d_ssHigh[bdx * (bdx -1) + idx] = 0.0;
    d_sLoc[bdx * bix + idx] = floor(log(d_sAgg[bdx * bix + idx] / fsVolCoeff) / log(fsVolBase) + 1);
    d_ssLoc[bdx * bix + idx] = floor(log(d_ssAgg[bdx * bix + idx] / ssVolCoeff) / log(ssVolBase) + 1);
    d_sInd[bdx * bix + idx] = (idx <= bix) ? (bix + 1) : (idx + 1);
    d_ssInd[bdx * bix + idx] = (idx <= bix) ? (bix + 1) : (idx + 1);
    __syncthreads();
    double value = d_vs[idx] - d_vs[bix];
    double value1 = d_vss[idx] - d_vss[bix];
    d_sBreak[bdx * bix + idx] = value < 0.0 ? 0.0 : value;
    d_ssBreak[bdx * bix + idx] = value1 < 0.0 ? 0.0 : value1;
    d_sLocBreak[bdx * bix + idx] = (d_sBreak[bdx * idx + bix] == 0) ? 0 : (floor(log(d_sBreak[bdx * idx + bix] / fsVolCoeff) / log(fsVolBase) + 1));
    d_ssLocBreak[bdx * bix + idx] = (d_ssBreak[bdx * idx + bix] == 0) ? 0 : (floor(log(d_ssBreak[bdx * idx + bix] / ssVolCoeff) / log(ssVolBase) + 1));
    __syncthreads();
    d_sCheckB[bdx * bix + idx] = d_sLocBreak[bdx * bix + idx] >= 1 ? 1 : 0;
    d_ssCheckB[bdx * bix + idx] = d_ssLocBreak[bdx * bix + idx] >= 1 ? 1 : 0;
    d_sIndB[bdx * bix + idx] = d_sLocBreak[bdx * bix + idx];
    d_ssIndB[bdx * bix + idx] = d_ssLocBreak[bdx * bix + idx];
    if (d_sIndB[bdx * bix + idx] < 1)
        d_sIndB[bdx * bix + idx] = bdx + 1;
    if (d_ssIndB[bdx * bix + idx] < 1)
        d_ssIndB[bdx * bix + idx] = bdx + 1;
}


int main(int argc, char *argv[])
{
    cout << "Code begins..." << endl;
    // Read passed arguments
    string startTimeStr;
    double startTime = 0.0;
    liggghtsData *lData = nullptr;
    parameterData *pData = nullptr;

    string coreVal;
    string diaVal;
    string pbmInFilePath;
    string timeVal;

    if (argc <5)
    {
        cout << "All values are not available as imput parameters " << endl;
        return 1;
    }

    pbmInFilePath = string(argv[1]);
    coreVal = string(argv[2]);
    diaVal = string(argv[3]);
    timeVal = string(argv[4]);

    pData = parameterData::getInstance();
    pData->readPBMInputFile(pbmInFilePath);

    int nCompartments = pData->nCompartments;
    // CompartmentIn CompartmentIn;
    // PreviousCompartmentIn prevCompInData;
    // CompartmentOut compartmentOut;

    unsigned int nFirstSolidBins = pData->nFirstSolidBins;
    unsigned int nSecondSolidBins = pData->nSecondSolidBins;

    size_t size1D = nFirstSolidBins;
    size_t size2D = nFirstSolidBins * nSecondSolidBins;
    size_t size3D = nFirstSolidBins * nSecondSolidBins * nCompartments;

    vector<double> h_vs(size1D, 0.0);
    vector<double> h_vss(size1D, 0.0);
    
    // Bin Initiation
    double fsVolCoeff = pData->fsVolCoeff;
    double fsVolBase = pData->fsVolBase;
    for (size_t i = 0; i < nFirstSolidBins; i++)
        h_vs[i] = fsVolCoeff * pow(fsVolBase, i); // m^3

    double ssVolCoeff = pData->ssVolCoeff;
    double ssVolBase = pData->ssVolBase;
    for (size_t i = 0; i < nSecondSolidBins; i++) 
        h_vss[i] = ssVolCoeff * pow(ssVolBase, i); // m^3

    arrayOfDouble2D diameter = getArrayOfDouble2D(nFirstSolidBins, nSecondSolidBins);
    for (size_t s = 0; s < nFirstSolidBins; s++)
        for (size_t ss = 0; ss < nSecondSolidBins; ss++)
            diameter[s][ss] = cbrt((6/M_PI) * (h_vs[s] + h_vss[ss]));
    
    vector<double> particleIn;
    particleIn.push_back(726657587.0);
    particleIn.push_back(286654401.0);
    particleIn.push_back(118218011.0);
    particleIn.push_back(50319795.0);
    particleIn.push_back(20954036.0);
    particleIn.push_back(7345998.0);
    particleIn.push_back(1500147.0);
    particleIn.push_back(76518.0);
    particleIn.push_back(149.0);
    
    vector<double> h_fIn(size2D, 0.0);
    for (size_t i = 0; i < size2D; i++)
        h_fIn[i * particleIn.size() + i] = particleIn[i];
    
    vector<double> h_sMeshXY(size2D, 0.0);
    vector<double> h_ssMeshXY(size2D, 0.0);

    // allocation of memory for the matrices that will be copied onto the device from the host
    double *d_vs = device_alloc_double_vector(size1D);
    double *d_vss = device_alloc_double_vector(size1D);
    
    double *d_sMeshXY = device_alloc_double_vector(size2D);
    double *d_ssMeshXY = device_alloc_double_vector(size2D);

    double *d_sAgg = device_alloc_double_vector(size2D);
    double *d_ssAgg = device_alloc_double_vector(size2D);

    int *d_sAggregationCheck = device_alloc_integer_vector(size2D);
    int *d_ssAggregationCheck = device_alloc_integer_vector(size2D);

    double *d_sLow = device_alloc_double_vector(size2D);
    double *d_ssLow = device_alloc_double_vector(size2D);

    double *d_sHigh = device_alloc_double_vector(size2D);
    double *d_ssHigh = device_alloc_double_vector(size2D);

    int *d_sLoc = device_alloc_integer_vector(size2D);
    int *d_ssLoc = device_alloc_integer_vector(size2D);

    int *d_sInd = device_alloc_integer_vector(size2D);
    int *d_ssInd = device_alloc_integer_vector(size2D);

    double *d_sBreak = device_alloc_double_vector(size2D);
    double *d_ssBreak = device_alloc_double_vector(size2D);

    int *d_sLocBreak = device_alloc_integer_vector(size2D);
    int *d_ssLocBreak = device_alloc_integer_vector(size2D);

    int *d_sCheckB = device_alloc_integer_vector(size2D);
    int *d_ssCheckB = device_alloc_integer_vector(size2D);

    int *d_sIndB = device_alloc_integer_vector(size2D);
    int *d_ssIndB = device_alloc_integer_vector(size2D);

    vector<int> h_sBreak(size2D, 0.0);
    vector<int> h_ssBreak(size2D, 0.0);

    copy_double_vector_fromHtoD(d_vs, h_vs.data(), size1D);
    copy_double_vector_fromHtoD(d_vss, h_vss.data(), size1D);

    int nBlocks = NBLOCKS;
    int nThreads = NTHREADS;

    initialization_kernel<<<16,16>>>(d_vs, d_vss, size2D, fsVolCoeff, ssVolCoeff, fsVolBase, ssVolBase, d_sAgg,d_ssAgg, d_sAggregationCheck, d_ssAggregationCheck, 
                                    d_sLow, d_ssLow, d_sHigh, d_ssHigh, d_sMeshXY, d_ssMeshXY, d_sLoc, d_ssLoc, d_sInd, d_ssInd, d_sBreak, d_ssBreak, d_sLocBreak, d_ssLocBreak,
                                    d_sCheckB, d_ssCheckB, d_sIndB, d_ssIndB);
    cudaError_t err = cudaSuccess;
    err = cudaGetLastError();
    if (err != cudaSuccess)
    {
        fprintf(stderr, "Failed to launch initialization kernel (error code %s)!\n", cudaGetErrorString(err));
        exit(EXIT_FAILURE);
    }
    cout << "Initialization complete" << endl;


    copy_integer_vector_fromDtoH(h_sBreak.data(), d_ssIndB, size2D);
    copy_integer_vector_fromDtoH(h_ssBreak.data(), d_ssIndB, size2D);
    cudaDeviceSynchronize();

    vector<double> h_fAllCompartments(size3D, 0.0);
    vector<double> h_flAllCompartments(size3D, 0.0);
    vector<double> h_fgAllCompartments(size3D, 0.0);

    vector<double> h_dfdtAllCompartments(size3D, 0.0);
    vector<double> h_dfldtAllCompartments(size3D, 0.0);
    vector<double> h_dfgdtAllCompartments(size3D, 0.0);
    
    vector<double> h_externalVolumeBinsAllCompartments(size3D, 0.0);
    vector<double> h_internalVolumeBinsAllCompartments(size3D, 0.0);
    vector<double> h_liquidBinsAllCompartments(size3D, 0.0);
    vector<double> h_gasBinsAllCompartments(size3D, 0.0);
    vector<double> h_totalVolumeBinsAllCompartments(size3D, 0.0);
    
    vector<double> h_internalLiquidAllCompartments(size3D, 0.0);
    vector<double> h_externalLiquidAllCompartments(size3D, 0.0);
    
    vector<double> h_internalVolumeBins(size2D, 0.0);
    vector<double> h_externalVolumeBins(size2D, 0.0);

    lData = liggghtsData::getInstance();
    lData->readLiggghtsDataFiles(coreVal, diaVal);

    vector<double> DEMDiameter = lData->getDEMParticleDiameters();
    if ((DEMDiameter).size() == 0)
    {
        cout << "Diameter data is missing in LIGGGHTS output file" << endl;
        cout << "Input parameters for DEM core and diameter aren't matching with LIGGGHTS output file" << endl;
        return 1;
    }

    vector<double> DEMImpactData = lData->getFinalDEMImpactData();
    if ((DEMImpactData).size() == 0)
    {
        cout << "Impact data is missing in LIGGGHTS output file" << endl;
        cout << "Input parameters for DEM core and diameter aren't matching with LIGGGHTS output file" << endl;
        return 1;
    }

    arrayOfDouble2D DEMCollisionData = lData->getFinalDEMCollisionData();
    if (DEMCollisionData.size() == 0)
    {
        cout << "Collision data is missing in LIGGGHTS output file" << endl;
        cout << "Input parameters for DEM core and diameter aren't matching with LIGGGHTS output file" << endl;
        return 1;
    }
    vector<double> velocity = lData->getFinalDEMImpactVelocity();
    if (velocity.size() == 0)
    {
        cout << "Velocity is missing in LIGGGHTS output file" << endl;
        cout << "Input parameters for DEM core and diameter aren't matching with LIGGGHTS output file" << endl;
	    return 1;
    }

    DUMP2D(DEMCollisionData);
    DUMP(DEMDiameter);
    DUMP(DEMImpactData);
    DUMP(velocity);

    vector<double> liquidAdditionRateAllCompartments(nCompartments, 0.0);
    double liqSolidRatio = pData->liqSolidRatio;
    double throughput = pData->throughput;
    double liqDensity = pData->liqDensity;
    double liquidAddRate = (liqSolidRatio * throughput) / (liqDensity * 3600);
    liquidAdditionRateAllCompartments[0] = liquidAddRate;
    
    arrayOfDouble4D fAllCompartmentsOverTime;
    arrayOfDouble4D externalVolumeBinsAllCompartmentsOverTime;
    arrayOfDouble4D internalVolumeBinsAllCompartmentsOverTime;
    arrayOfDouble4D liquidBinsAllCompartmentsOverTime;
    arrayOfDouble4D gasBinsAllCompartmentsOverTime;

    double granulatorLength = pData->granulatorLength;
    double partticleResTime = pData->partticleResTime;
    double particleAveVelo = granulatorLength /  partticleResTime;
    vector<double> particleAverageVelocity(nCompartments, particleAveVelo);








    cudaFree(d_vs);
    cudaFree(d_vss);
    // cudaFree(d_sMeshXY);
    // cudaFree(d_ssMeshXY);
}