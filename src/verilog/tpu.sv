import tpu_pkg::*;

// N x N INT8 output-stationary systolic tile.
// out[r][c] = sum_{i<k} X[r][i] * W[c][i]  (mod 2^32), the xtpu tile semantics
// used by the Neural_Accelerator Spike model.
module tpu (
    input  logic i_clk,
    input  logic i_rst_n,

    input  logic i_start,
    input  logic [KLEN_WIDTH-1:0] i_k,
    output logic o_done,
    output logic o_busy,

    // Host writes are accepted only while idle.
    input  logic i_host_wenable,
    input  logic [ADDR_WIDTH-1:0] i_host_waddr,
    input  logic [DATA_WIDTH-1:0] i_host_wdata,
    output logic o_host_wready,

    // Host reads of the OUT region return one accumulator, one cycle later.
    input  logic i_host_renable,
    input  logic [ADDR_WIDTH-1:0] i_host_raddr,
    output logic [ACC_WIDTH-1:0] o_host_rdata,
    output logic o_host_valid
);

    localparam int N = ARRAY_SIZE;

    logic fsm_clear;
    logic fsm_rd_enable;
    logic [K_WIDTH-1:0] fsm_rd_index;

    tpu_fsm u_fsm (
        .i_clk       (i_clk),
        .i_rst_n     (i_rst_n),
        .i_start     (i_start),
        .i_k         (i_k),
        .o_done      (o_done),
        .o_busy      (o_busy),
        .o_clear     (fsm_clear),
        .o_rd_enable (fsm_rd_enable),
        .o_rd_index  (fsm_rd_index)
    );

    logic [N-1:0][DATA_WIDTH-1:0] buf_act_vec;
    logic [N-1:0][DATA_WIDTH-1:0] buf_weight_vec;
    logic buf_valid;

    assign o_host_wready = ~o_busy;

    unified_buffer u_buffer (
        .i_clk          (i_clk),
        .i_host_wenable (i_host_wenable & ~o_busy),
        .i_host_waddr   (i_host_waddr),
        .i_host_wdata   (i_host_wdata),
        .i_rd_enable    (fsm_rd_enable),
        .i_rd_index     (fsm_rd_index),
        .o_act_vec      (buf_act_vec),
        .o_weight_vec   (buf_weight_vec)
    );

    // Buffer reads have one cycle of latency.
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n)
            buf_valid <= 1'b0;
        else
            buf_valid <= fsm_rd_enable;
    end

    // Row r and column c are both delayed r+1 / c+1 cycles, so X[r][i] and
    // W[c][i] meet in PE(r,c) on the same cycle.
    logic [N-1:0][DATA_WIDTH-1:0] sds_act;
    logic [N-1:0][DATA_WIDTH-1:0] sds_weight;
    logic [N-1:0] sds_act_valid;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [N-1:0] sds_weight_valid;
    /* verilator lint_on UNUSEDSIGNAL */

    systolic_data_setup #(.LANES(N), .WIDTH(DATA_WIDTH)) u_sds_act (
        .i_clk   (i_clk),
        .i_rst_n (i_rst_n),
        .i_valid (buf_valid),
        .i_data  (buf_act_vec),
        .o_data  (sds_act),
        .o_valid (sds_act_valid)
    );

    systolic_data_setup #(.LANES(N), .WIDTH(DATA_WIDTH)) u_sds_weight (
        .i_clk   (i_clk),
        .i_rst_n (i_rst_n),
        .i_valid (buf_valid),
        .i_data  (buf_weight_vec),
        .o_data  (sds_weight),
        .o_valid (sds_weight_valid)
    );

    logic [N-1:0][N-1:0][DATA_WIDTH-1:0] mac_act_in, mac_weight_in;
    logic [N-1:0][N-1:0] mac_valid_in;
    // The last column's activations and the last row's weights leave the array unused.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [N-1:0][N-1:0][DATA_WIDTH-1:0] mac_act_out, mac_weight_out;
    logic [N-1:0][N-1:0] mac_valid_out;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [N-1:0][N-1:0][ACC_WIDTH-1:0] mac_acc;
    logic [N*N*ACC_WIDTH-1:0] acc_bus; // row-major, for host readout

    genvar gi, gj;
    generate
        for (gi = 0; gi < N; gi++) begin : mac_row
            for (gj = 0; gj < N; gj++) begin : mac_col

                if (gj == 0) begin : g_left_edge
                    assign mac_act_in[gi][gj] = sds_act[gi];
                    assign mac_valid_in[gi][gj] = sds_act_valid[gi];
                end else begin : g_from_left
                    assign mac_act_in[gi][gj] = mac_act_out[gi][gj-1];
                    assign mac_valid_in[gi][gj] = mac_valid_out[gi][gj-1];
                end

                if (gi == 0) begin : g_top_edge
                    assign mac_weight_in[gi][gj] = sds_weight[gj];
                end else begin : g_from_above
                    assign mac_weight_in[gi][gj] = mac_weight_out[gi-1][gj];
                end

                assign acc_bus[(gi*N + gj)*ACC_WIDTH +: ACC_WIDTH] = mac_acc[gi][gj];

                mac_cell u_mac (
                    .i_clk    (i_clk),
                    .i_rst_n  (i_rst_n),
                    .i_clear  (fsm_clear),
                    .i_valid  (mac_valid_in[gi][gj]),
                    .i_act    (mac_act_in[gi][gj]),
                    .i_weight (mac_weight_in[gi][gj]),
                    .o_valid  (mac_valid_out[gi][gj]),
                    .o_act    (mac_act_out[gi][gj]),
                    .o_weight (mac_weight_out[gi][gj]),
                    .o_acc    (mac_acc[gi][gj])
                );
            end
        end
    endgenerate

    // Result readout straight from the accumulators.
    logic [1:0] r_region;
    logic [IDX_WIDTH-1:0] r_row;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [K_WIDTH-1:0] r_index; // OUT region uses only the column bits
    /* verilator lint_on UNUSEDSIGNAL */
    logic host_read;
    logic [2*IDX_WIDTH-1:0] r_elem;

    assign {r_region, r_row, r_index} = i_host_raddr;
    assign host_read = i_host_renable & ~o_busy;
    assign r_elem = {r_row, r_index[IDX_WIDTH-1:0]};

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_host_valid <= 1'b0;
            o_host_rdata <= '0;
        end else begin
            o_host_valid <= host_read;
            if (host_read)
                o_host_rdata <= (r_region == REGION_OUT) ? acc_bus[r_elem*ACC_WIDTH +: ACC_WIDTH] : '0;
        end
    end

endmodule
