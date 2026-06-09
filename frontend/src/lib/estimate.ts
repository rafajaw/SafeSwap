import { formatUnits } from "viem";
import type { TokenClass } from "./tokens";

/**
 * Tier A transparent demo benchmark (handoff §4). Estimates value protected versus an ASSUMED ordinary-execution MEV loss,
 * expressed in INPUT-TOKEN terms (no USD on day 1). Every output is a modeled estimate and must be labeled as such — never
 * presented as a realized saving. The benchmark is selected by pair volatility class and trade size, never one hidden number.
 *
 *   baseline_mev_loss            = input × assumed_mev_loss_bps / 10,000
 *   incremental_safeswap_cost    = repricing_fee (the SafeSwap-specific surplus charge; base LP fee exists on any DEX)
 *   estimated_value_protected    = max(0, baseline_mev_loss − incremental_safeswap_cost)
 *   estimated_improvement        = estimated_value_protected / input
 *
 * Gas is intentionally excluded on day 1 (and the UI says so). The model is replaceable without touching the tx flow.
 */

/** Assumed ordinary-execution MEV loss (bps) by pair volatility class — the demo baseline. */
const ASSUMED_MEV_LOSS_BPS: Record<TokenClass, number>  =  {
    stable:   3,
    bluechip: 14,
    longtail: 40,
};

export type ValueEstimate = {
    /** Estimated value protected, in input-token units (display number). */
    value_input_terms:    number;
    /** Estimated improvement as a fraction of input (e.g. 0.0031 = +0.31%). */
    improvement_fraction: number;
    confidence:           "low" | "medium" | "high";
    methodology:          "demo_benchmark";
    baseline_mev_loss_bps: number;
    includes_gas:          boolean;
    /** Human methodology line for the `How calculated` disclosure. */
    assumption_text:       string;
    input_symbol:          string;
};

export function estimate_value_protected( params: {
    input_amount:   bigint;
    input_decimals: number;
    input_symbol:   string;
    /** Total LP fee the quoter returned (v4 pips). */
    total_fee_pips: number;
    /** Base LP fee component (v4 pips) = base_fee_bps × 100. */
    base_fee_pips:  number;
    pair_class:     TokenClass;
}): ValueEstimate
{
    const input            =  Number( formatUnits( params.input_amount, params.input_decimals ) );
    const baseline_bps     =  size_adjusted_bps( ASSUMED_MEV_LOSS_BPS[ params.pair_class ], input, params.pair_class );
    const baseline_loss    =  input * baseline_bps / 10_000;

    const repricing_pips   =  Math.max( 0, params.total_fee_pips - params.base_fee_pips );
    const repricing_fee    =  input * repricing_pips / 1_000_000;

    const value_protected  =  Math.max( 0, baseline_loss - repricing_fee );

    return {
        value_input_terms:     value_protected,
        improvement_fraction:  input > 0 ? value_protected / input : 0,
        confidence:            "low",
        methodology:           "demo_benchmark",
        baseline_mev_loss_bps: baseline_bps,
        includes_gas:          false,
        input_symbol:          params.input_symbol,
        assumption_text:
            `Estimated improvement compares SafeSwap execution with an assumed ordinary-execution MEV loss of ` +
            `${ ( baseline_bps / 100 ).toFixed( 2 ) }% for this pair class, minus the estimated repricing fee. Gas is not ` +
            `included. Actual outcomes vary with route, size, volatility, liquidity, ordering and market conditions.`,
    };
}

/** Larger trades (relative to a nominal size) assume slightly more MEV exposure — a coarse demo proxy for size/liquidity. */
function size_adjusted_bps( base_bps: number, input: number, klass: TokenClass ): number
{
    const reference  =  klass === "stable" ? 50_000 : klass === "bluechip" ? 25 : 5_000;
    const factor     =  1 + Math.min( 0.5, input / reference );
    return Math.round( base_bps * factor );
}
