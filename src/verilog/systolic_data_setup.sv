// Skews a vector so that lane i leaves i+1 cycles after it enters.
// Used on both array edges: activation rows (left) and weight columns (top).
module systolic_data_setup #(
    parameter integer LANES = 8,
    parameter integer WIDTH = 8
) (
    input  logic i_clk,
    input  logic i_rst_n,
    input  logic i_valid,
    input  logic [LANES-1:0][WIDTH-1:0] i_data,
    output logic [LANES-1:0][WIDTH-1:0] o_data,
    output logic [LANES-1:0] o_valid
);
    // Each lane is a shift register; lane i taps stage i. Unused upper stages
    // are removed by synthesis.
    for (genvar i = 0; i < LANES; i++) begin : g_lane
        /* verilator lint_off UNUSEDSIGNAL */
        logic [LANES*WIDTH-1:0] skew_pipe;
        logic [LANES-1:0] valid_pipe;
        /* verilator lint_on UNUSEDSIGNAL */

        always_ff @(posedge i_clk or negedge i_rst_n) begin
            if (!i_rst_n) begin // initialize empty pipeline
                skew_pipe <= '0;
                valid_pipe <= '0;
            end else begin
                // feed 0 when invalid, so pipeline drains cleanly
                skew_pipe <= {skew_pipe[(LANES-1)*WIDTH-1:0], (i_valid ? i_data[i] : WIDTH'(0))};
                valid_pipe <= {valid_pipe[LANES-2:0], i_valid};
            end
        end

        assign o_data[i] = skew_pipe[i*WIDTH +: WIDTH];
        assign o_valid[i] = valid_pipe[i];
    end
endmodule
