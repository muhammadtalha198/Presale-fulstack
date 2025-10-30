const TokenBalance = () => {
  return (
    <div className="w-full py-4 md:py-6 px-3 md:px-4 flex items-center justify-between bg-gray/5 tracking-tight rounded-l-md rounded-r-md">
      <span className="text-bg-logo text-[14px] md:text-sm font-medium">Your $ESCROW balance</span>
      <span className="text-bg-logo text-[14px] md:text-sm font-medium">0 $ESCROW</span>
    </div>
  );
}
 
export default TokenBalance;