import tpu_pkg::*;

// Operand buffers: one memory per array lane for X and W.
// The host writes one INT8 element per cycle; the engine reads a whole
// N-element column (X[:, i] and W[:, i]) per cycle.
module unified_buffer (
    input  logic i_clk,

    input  logic i_host_wenable,
    input  logic [ADDR_WIDTH-1:0] i_host_waddr,
    input  logic [DATA_WIDTH-1:0] i_host_wdata,

    input  logic i_rd_enable,
    input  logic [K_WIDTH-1:0] i_rd_index,
    output logic [ARRAY_SIZE-1:0][DATA_WIDTH-1:0] o_act_vec,
    output logic [ARRAY_SIZE-1:0][DATA_WIDTH-1:0] o_weight_vec
);
    logic [1:0] w_region;
    logic [IDX_WIDTH-1:0] w_lane;
    logic [K_WIDTH-1:0] w_index;

    assign {w_region, w_lane, w_index} = i_host_waddr;

    for (genvar g = 0; g < ARRAY_SIZE; g++) begin : g_lane
        logic [DATA_WIDTH-1:0] act_mem [K_MAX];
        logic [DATA_WIDTH-1:0] weight_mem [K_MAX];
        logic [DATA_WIDTH-1:0] act_q, weight_q;

        always_ff @(posedge i_clk) begin
            if (i_host_wenable && w_region == REGION_X && w_lane == IDX_WIDTH'(g))
                act_mem[w_index] <= i_host_wdata;
            if (i_rd_enable)
                act_q <= act_mem[i_rd_index];
        end

        always_ff @(posedge i_clk) begin
            if (i_host_wenable && w_region == REGION_W && w_lane == IDX_WIDTH'(g))
                weight_mem[w_index] <= i_host_wdata;
            if (i_rd_enable)
                weight_q <= weight_mem[i_rd_index];
        end

        assign o_act_vec[g] = act_q;
        assign o_weight_vec[g] = weight_q;
    end

endmodule
