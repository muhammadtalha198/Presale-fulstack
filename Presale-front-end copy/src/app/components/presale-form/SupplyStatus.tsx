'use client'

import { useMemo } from "react";

type Props = {
  presaleSupply: number;
  tokensSold: number;
}

const SupplyStatus = ({ presaleSupply, tokensSold }: Props) => {

  const percentajeSold = useMemo(() => {
    return Math.floor((tokensSold / presaleSupply) * 100);
  }, [tokensSold, presaleSupply]);

  function formatQuantity(num: number) {
    if(num >= 1_000_000_000_000) {
      return (num / 1_000_000_000_000).toFixed(2) + 'T';
    } else if (num >= 1_000_000_000) {
      return (num / 1_000_000_000).toFixed(2) + 'B';
    } else if (num >= 1_000_000) {
      return (num / 1_000_000).toFixed(2) + 'M';
    } else {
      return num.toString();
    }
  }

  return (
    <div>
      <div className="w-full flex items-center justify-between flex-nowrap tracking-tighter !text-sm">
        <span className="text-bg-logo font-medium">{formatQuantity(tokensSold)} Tokens sold</span>
        <span className="text-bg-logo">{formatQuantity(presaleSupply - tokensSold)} Tokens remaining</span>
      </div>
      <div className="relative w-full my-2 p-1 rounded-l-full rounded-r-full border-body-text border-[1px] ">
        <div style={{ width: `${percentajeSold}%` }} className={`h-2 rounded-l-full rounded-r-full bg-gradient-to-r from-logo-grad-green from-0% via-logo-grad-blue via-30% to-logo-grad-purple to-80%`}></div>
      </div>
      <div className="w-full text-right text-sm font-medium text-bg-logo">
        Total sale volume: 12.00B
      </div>
    </div>
  );
}
 
export default SupplyStatus;