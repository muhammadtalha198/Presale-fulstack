import { ConnectButton, darkTheme } from "@rainbow-me/rainbowkit";
import Image from "next/image";
import CustomConnectButton from "./CustomConnectButton";

const NavBar = () => {
  return (
    <header className="sticky flex flex-col w-full top-0 px-2 md:px-4 py-2 box-border z-50 bg-[#101010] ">
      <div className="w-full mb-2 flex items-center justify-between">
        <div className="w-fit flex items-center justify-between">
          <Image className="mr-2" src={'/escrow-logo.svg'} alt="escrow logo" height={8} width={30}/>
          <h1 className="text-bg-logo font-semibold">iEscrow</h1>
        </div>
        <CustomConnectButton />
      </div>
      <div className="w-full h-[1px] bg-body-text"></div>
    </header>
  );
}
 
export default NavBar;