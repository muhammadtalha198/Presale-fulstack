type Props = {
  title: string;
  subtitle: string
}

const TokenPrice = ({ title, subtitle }: Props) => {
  return (
    <div className="w-full flex flex-nowrap items-center justify-center my-8 md:my-12">
      <div className="flex-1 h-[2px] bg-[linear-gradient(to_left,transparent_10%,theme(colors.bg-logo)_50%,transparent_90%)]"></div>      
      <div className="flex flex-[0_0_auto] flex-col items-center justify-center">
        <span className="text-base lg:text-md font-semibold text-bg-logo mb-1 rounded-l-full rounded-r-full"> {title} </span>
        <span className="font-bold text-md md:text-lg text-light-blue rounded-l-full rounded-r-full"> {subtitle} </span>
      </div>
      <div className="flex-1 h-[2px] bg-[linear-gradient(to_left,transparent_10%,theme(colors.bg-logo)_50%,transparent_90%)]"></div>    
    </div>
  );
}

export default TokenPrice;