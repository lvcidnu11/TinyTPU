import tpu_pkg::*;

// Output-stationary processing element.
// Activations move right, weights move down, and the INT32 partial sum stays in the cell.
module mac_cell (
    input  logic i_clk,
    input  logic i_rst_n,
    input  logic i_clear,                       // zero the accumulator before a new tile
    input  logic i_valid,                       // travels with the activation
    input  logic signed [DATA_WIDTH-1:0] i_act, // from the left neighbour
    input  logic signed [DATA_WIDTH-1:0] i_weight, // from the upper neighbour
    output logic o_valid,
    output logic signed [DATA_WIDTH-1:0] o_act,
    output logic signed [DATA_WIDTH-1:0] o_weight,
    output logic [ACC_WIDTH-1:0] o_acc
);
    logic signed [2*DATA_WIDTH-1:0] product;
    logic [ACC_WIDTH-1:0] product_ext;

    assign product = i_act * i_weight;
    assign product_ext = {{(ACC_WIDTH-2*DATA_WIDTH){product[2*DATA_WIDTH-1]}}, product};

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_valid <= 1'b0;
            o_act <= '0;
            o_weight <= '0;
            o_acc <= '0;
        end else begin
            o_valid <= i_valid;
            o_act <= i_act;
            o_weight <= i_weight;
            if (i_clear)
                o_acc <= '0;
            else if (i_valid)
                o_acc <= o_acc + product_ext; // wraps modulo 2^32, matching xtpu
        end
    end

endmodule
