{{ config(
        alias = 'glp_float',
        materialized = 'view',
        post_hook='{{ expose_spells(\'["arbitrum"]\',
                                    "project",
                                    "gmx",
                                    \'["1chioku"]\') }}'
        )
}}

WITH minute AS  -- This CTE generates a series of minute values
    (
    SELECT explode(sequence(TIMESTAMP '2021-08-31 08:13', CURRENT_TIMESTAMP, INTERVAL 1 minute)) AS minute -- 2021-08-31 08:13 is the timestamp of the first vault transaction
    ) ,

/*
GLP tokens are minted and burned by the GLP Manager contract by invoking addLiquidity() and removeLiquidity()
The GLP Manager contract can be found here: https://arbiscan.io/address/0x321F653eED006AD1C29D174e17d96351BDe22649
*/

glp_balances AS -- This CTE returns the accuals of WETH tokens in the Fee GLP contract in a designated minute
    (    
    SELECT -- This subquery aggregates the mints and burns of GLP tokens over the minute series
        b.minute,
        b.glp_mint_burn_value,
        SUM(b.glp_mint_burn_value) OVER (ORDER BY b.minute ASC) AS glp_cum_balance
    FROM
        (
        SELECT  -- This subquery aggregates all the inbound tranfers of mints and burns of GLP tokens in a designated minute
            a.minute,
            SUM(a.mint_burn_value) AS glp_mint_burn_value
        FROM
            (
            SELECT  -- This subquery truncates the block time to a minute and selects all mints and burns of GLP tokens through the GLP Manager contract
                date_trunc('minute', evt_block_time) AS minute,
                mintAmount/1e18 AS mint_burn_value
            FROM {{source('gmx_arbitrum', 'GlpManager_evt_AddLiquidity')}}
            UNION
            SELECT
                date_trunc('minute', evt_block_time) AS minute,
                (-1 * glpAmount)/1e18 AS mint_burn_value
            FROM {{source('gmx_arbitrum', 'GlpManager_evt_RemoveLiquidity')}}
            ) a
        GROUP BY a.minute
        ) b
    )

SELECT
    x.minute,
    COALESCE(x.glp_mint_burn,0) AS glp_mint_burn, -- Removes null values
    COALESCE(x.glp_float,0) AS glp_float -- Removes null values
FROM
    (
    SELECT
        a.minute AS minute,
        b.glp_mint_burn_value AS glp_mint_burn,
        last(b.glp_cum_balance, true) OVER (ORDER BY a.minute ASC) AS glp_float -- extrapolation
    FROM minute a    
    LEFT JOIN
        (
        SELECT
            minute,
            glp_mint_burn_value,
            glp_cum_balance
        FROM glp_balances 
        ) b
        ON a.minute = b.minute
    ) x