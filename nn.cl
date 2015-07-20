#include "/home/parallella/Work/nnP/coreId16.inc"
//#include <e32_opencl_ext.h>
//#include <coprthr_device.h>

#include "/home/parallella/Work/nnP/cldefs.inc"
/// cldefs.inc contains #defines for all static variables
/// example contents of cldefs.inc
///#define CORECOUNT 16
///#define LAYERCOUNT 4
///#define OUTPUTLAYER 3                 // LAYERCOUNT -1
///#define MAXWEIGHTTOLAYER 1024
///#define LARGESTDERIVEDLAYER 32
///#define LARGESTINPUTLAYER 32          // max of all the layers that feed into other layers
///#define TOTALDERIVEDNODES 58  /// the sum of the nodes from layer 1 onwards
///#define INITWIDTHARRAY {32,32,16,16}

void forwardPass(   float * g_inVals,
                    float * g_nodeBiases,
                    float * biases,
                    float * g_weights,
                    float * wgt,
                    float * derived,
                    int   * widths,
                    int * finalFirstNode,
                    int * finalLastNode,
           __global float * debug)
{
    int n, i, w;            /// node, input, weight
    int d = 0;              /// debug
    int gid = get_global_id(0);
    int layer;
    int firstNode, lastNode;                /// the index of the first and last nodes in the __global node array
    int localFirstNode, localLastNode;      /// the  index of the first and last nodes in the current layer
    int firstWeight, lastWeight;
    int nodeIndexOffset = 0;
    int wgtIndexOffset = 0;
    int destNodesPerCore, destNodesModulus;
    int curLayerWidth, prevLayerWidth;      /// convenience variables - saves having to do an array look up all the time
    float activationQuant;
    unsigned int core[] = {core00, core01, core02, core03, core10, core11, core12, core13, core20, core21, core22, core23, core30, core31, core32, core33};
    unsigned int coreI;
    unsigned int localCoreId = LOCAL_MEM_ADDRESS_BASE(gid);


    /// local storage
//    __private int   widths[] = INITWIDTHARRAY;
    __private float in[LARGESTINPUTLAYER];

    if(gid==0)
        for (i=0;i<TOTALDERIVEDNODES;i++)
            debug[i] = 0;

    for(layer = 1; layer<LAYERCOUNT; layer++)
    {
        curLayerWidth = widths[layer];
        prevLayerWidth = widths[layer-1];

        destNodesPerCore = curLayerWidth / CORECOUNT;                   /// all cores get this many
        destNodesModulus = curLayerWidth % CORECOUNT;                   /// the remainder are assigned one per node starting from gid == 0

        firstNode = nodeIndexOffset + ((gid * destNodesPerCore) + min(gid, destNodesModulus)); /// all node biases are in one big array so nodeIndexOffset records where the current layer starts
        lastNode = firstNode + destNodesPerCore + ((gid < destNodesModulus) ? 1 : 0);
        localFirstNode = firstNode - nodeIndexOffset;                   /// firstNode - nodeIndexOffset is the node index within the current  layer
        localLastNode = lastNode - nodeIndexOffset;                     /// localFirstNode and localLastNode align with the derived value array
        firstWeight = wgtIndexOffset + (localFirstNode * prevLayerWidth);
        lastWeight = firstWeight + ((lastNode - firstNode) * prevLayerWidth);

      ///memcopy(...);     /// only copy in the g_weights that are needed for this node
        w=0;
        for (i=firstWeight; i<lastWeight; i++)
            wgt[w++] = g_weights[i];

        /// memcopy(..);
        if (layer == 1)                             /// input layer to first hidden layer
            for (i=0; i<widths[0]; i++)
                in[i] = g_inVals[i];
        else                                        /// all other layers
        {
            n = nodeIndexOffset - prevLayerWidth;    /// start from the begining of the previous layer's values in the derived value array
            for (i=0; i<prevLayerWidth; i++)
                in[i] = derived[n++];
        }

//        if (gid == 0)
//        {
//            for (i=0; i<prevLayerWidth; i++)
//                debug[d++] = in[i];
//            debug[d++] = 1000.0;
//        }

//            /// testing - inialise the derived layer to see what values have ben calculated
//        for (i=0; i<LARGESTDERIVEDLAYER; i++)
//            derived[i]= (float)1.0;

        ///memcopy(..);
        for (n = firstNode; n < lastNode; n++)
            biases[n] = g_nodeBiases[n];              /// allocate enough space for a whole bias vector in the layer but only copy the one this core needs


        firstWeight = 0;                            /// only the g_weights relevant to thse nodes have been copied into local memory
        lastWeight = prevLayerWidth;               /// check boundry condition on the very last weight into the output layer
        for (n = firstNode; n < lastNode; n++)
        {
            activationQuant = 0.0;
            i=0;                                    /// i is the index into the input vector which starts for 0 for every node;
            for (w=firstWeight; w<lastWeight; w++)
            {
                activationQuant += in[i++] * wgt[w];
            }

            derived[n] = (1.0 / (1.0 + (float)exp(-(biases[n] + activationQuant))));      // sigmoid function f(t) = 1/(1 + e^(-t))

            firstWeight = lastWeight;
            lastWeight += prevLayerWidth;
        }

//        if (layer < OUTPUTLAYER)
//        {
            /// transmit the node values calculated here to all other cores.
            for (coreI = 0; coreI < CORECOUNT; coreI++)
            {
                if (core[coreI] != localCoreId)
                    for (n=firstNode; n < lastNode; n++)
                        *(float *)NEIGHBOUR_LOC(core[coreI], derived,  n, (sizeof(float))) = derived[n];

            }
            /// make sure that every core has passed all values before proceeding onto the next layer
            barrier(CLK_LOCAL_MEM_FENCE | CLK_GLOBAL_MEM_FENCE);

            nodeIndexOffset += curLayerWidth; /// the length of the node bias array is the sum of the layer widths
            wgtIndexOffset += curLayerWidth * prevLayerWidth;
 //       }
 //       else
         if (layer == OUTPUTLAYER)
       {
            *finalFirstNode = firstNode;    /// remember where we are before returning
            *finalLastNode = lastNode;

            if (gid==0)
                for (i=0;i<TOTALDERIVEDNODES;i++)
                    debug[i] = derived[i];
        }
    }
}

///======================================================================================================================

///         FEED FORWARD

///======================================================================================================================
__kernel void k_forward(    __global float * g_inVals,         /// incoming: the input values to the net
                            __global float * g_nodeBiases,     /// incoming: g_nodeBiases all in one big array
                            __global float * g_weights,        /// incoming: g_weights for all layers in one big array
                            __global float * g_outVals,        /// outgoing: the results of the run
                            __global float * debug)
{
    __private int   widths[] = INITWIDTHARRAY;
    int finalFirstNode, finalLastNode;
    int n0, n;

    __private float derived[TOTALDERIVEDNODES];  /// replace with sum of derived layers
    __private float wgt[MAXWEIGHTTOLAYER];                  /// space for local storage of weights ... is filled by the forward pass and used later to train
    __private float biases[TOTALDERIVEDNODES];


    forwardPass(g_inVals, g_nodeBiases, biases, g_weights, wgt, derived, widths, &finalFirstNode, &finalLastNode, debug);

    n0 = finalFirstNode - (TOTALDERIVEDNODES - widths[OUTPUTLAYER]);    /// convert the index of the final derived layer back to a zero base
    for(n=finalFirstNode; n<finalLastNode; n++)
        g_outVals[n0++] = derived[n];        /// put the last derived vector into g_outVals for transmission to the host


}

///======================================================================================================================

///         TRAIN

///======================================================================================================================
__kernel void k_train(    __global float * g_inVals,          /// incoming: the input values to the new
                          __global float * g_desiredVals,     /// incoming: the desired outputvalues
                          __global float * g_nodeBiases,      /// incoming: g_nodeBiases all in one big array
                          __global float * g_weights,         /// incoming: g_weights for all layers in one big array
                          __global float * g_error,          /// outgoing: the cumulative differentials between the actual output and the deisred output
                          __global float   learningRate,
                          __global float * debug)
{
    int firstNode, lastNode, localFirstNode, localLastNode;
    int n, w;
    int layer;                                          /// counts from n to 1
    int curLayerWidth, nextLayerWidth, prevLayerWidth, firstWeight, lastWeight;
//    int outboundNodesCoreGid;
    int destNodesPerCore, destNodesModulus;
    int nodeIndexOffset = 0;
    int wgtIndexOffset = 0;
    int gid = get_global_id(0);
    int d = 0;

    __private int   widths[] = INITWIDTHARRAY;
    __private float derived[TOTALDERIVEDNODES];        // could restrict this to the width of the output layer
    __private float delta[LARGESTDERIVEDLAYER];        // could restrict this to the width of the output layer
    __private float outputError[LARGESTDERIVEDLAYER];       ///
    __private float wgt[MAXWEIGHTTOLAYER];                  /// space for local storage of weights ... is filled by the forward pass and used later to train
    __private float biases[TOTALDERIVEDNODES];
//    __private float linkErrors[MAXWEIGHTTOLAYER];           /// SPACE FOR EACH CORE TO SEND THE PREVIOUS LAYER'S OUTBOUND LINK ERRORS // using debug[] for now

    unsigned int core[] = {core00, core01, core02, core03, core10, core11, core12, core13, core20, core21, core22, core23, core30, core31, core32, core33};

    forwardPass(g_inVals, g_nodeBiases, biases, g_weights, wgt, derived, widths, &localFirstNode, &localLastNode, debug);

    destNodesPerCore = prevLayerWidth / CORECOUNT;                   /// all cores get this many
    destNodesModulus = prevLayerWidth % CORECOUNT;                   /// the remainder are assigned one per node starting from gid == 0

    for (layer = OUTPUTLAYER; layer > 0; layer--)
    {
        if (layer == OUTPUTLAYER)
        {
            /// calculate the OUTPUT layer error
            for (n = localFirstNode; n < localLastNode; n++)
                outputError[n] = g_desiredVals[n] - derived[n];      /// width of desired == width outputlayer

            /// pass the final deltas back
            for(n = localFirstNode; n < localLastNode; n++)
                g_error[n] = outputError[n];

            /// calculate the weight update delta for each output node
            for(n = localFirstNode; n < localLastNode; n++)
                delta[n] = derived[n] * (1 - derived[n]) * outputError[n];      /// first derivative of the sigmoid function [Read and Marks pg65]
        }
        else
        {
            firstNode = nodeIndexOffset + ((gid * destNodesPerCore) + min(gid, destNodesModulus)); /// all node biases are in one big array so nodeIndexOffset records where the current layer starts
            lastNode = firstNode + destNodesPerCore + ((gid < destNodesModulus) ? 1 : 0);
            localFirstNode = firstNode - nodeIndexOffset;                   /// firstNode - nodeIndexOffset is the node index within the current  layer
            localLastNode = lastNode - nodeIndexOffset;                     /// localFirstNode and localLastNode align with the derived value array

            for (n = localFirstNode; n < localLastNode; n++)    // not sure about this
            {
                outputError[n] = 0;
                for (w = 0; w < nextLayerWidth; w++)
                    outputError[n] += debug[w];
            }

            for(n = localFirstNode; n < localLastNode; n++)
                delta[n] = derived[n] * (1 - derived[n]) * outputError[n];      /// What here?
        }

        /// online learning for now
        prevLayerWidth = widths[layer - 1];
        curLayerWidth = widths[layer];
        firstWeight = -00;                              /// update the __global g_weights array for now
        lastWeight = prevLayerWidth;               /// check boundry condition on the very last weight into the output layer
    //    outboundNodesCoreGid = 0;

    //    d = gid * (prevLayerWidth + 3) * (finalLastNode - finalFirstNode);      // DEBUG
        for (n = localFirstNode; n < localLastNode; n++)
        {
            for (w=firstWeight; w<lastWeight; w++)
            {
                //wgt[w] -= learningRate * delta[n] * derived[n];
                g_weights[w] -= learningRate * delta[n] * derived[n];       /// update the global weight array for now

    /* This bit is to send the weight errors directly to the owning node in the previous layer
                /// pass delta * weight to previous layer
                if (outboundNodesCoreGid < destNodesModulus)        // relies on the observation that the first method will work for the first weight sent to the first core without an extra node will still work
                    outboundNodesCoreGid = (int)floor((float)(w/(destNodesPerCore + 1)));
                else
                    outboundNodesCoreGid = (int)(CORECOUNT - ceil((float)(((prevLayerWidth + 1) - w) / destNodesPerCore)));

                *(float *)NEIGHBOUR_LOC(core[outboundNodesCoreGid], linkErrors, (w), (sizeof(float))) = (delta[n] * wgt[w]);  /// <<<<<<<<<<<<<<< w is not correct
    //            if(gid == 0)
    //                debug[d++] = wgt[w];
    */
     //               linkErrors[(n * curLayerWidth) + w] = (delta[n] * wgt[w]);
                /// Use Debug to communication between cores for now
                debug[(n * curLayerWidth) + w] = (delta[n] * wgt[w]);
            }

            /// update the node bias
            biases[n] -= learningRate * outputError[n];

            firstWeight = lastWeight;
            lastWeight += prevLayerWidth;
        }
        barrier(CLK_LOCAL_MEM_FENCE | CLK_GLOBAL_MEM_FENCE);        /// pause for every core to catch up before going onto the next layer
    }
}
