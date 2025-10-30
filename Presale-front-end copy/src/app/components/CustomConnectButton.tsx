'use client'

import { ConnectButton } from '@rainbow-me/rainbowkit';

const CustomConnectButton = () => {
  return (
    <ConnectButton.Custom>
      {({
        account,
        chain,
        openAccountModal,
        openChainModal,
        openConnectModal,
        authenticationStatus,
        mounted,
      }) => {
        // Note: If your app doesn't use authentication, you
        // can remove all 'authenticationStatus' checks
        const ready = mounted && authenticationStatus !== 'loading';
        const connected =
          ready &&
          account &&
          chain &&
          (!authenticationStatus ||
            authenticationStatus === 'authenticated');

        return (
          <div
            {...(!ready && {
              'aria-hidden': true,
              'style': {
                opacity: 0,
                pointerEvents: 'none',
                userSelect: 'none',
              },
            })}
          >
            {(() => {
              if (!connected) {
                return (
                  <button 
                    className='px-2 md:px-4 py-[2px] md:py-1 font-poppins tracking-tighter text-bg-logo text-sm border-[1px] border-bg-logo hover:bg-bg-logo hover:border-bg-logo hover:text-black duration-200 rounded-l-full rounded-r-full cursor-pointer' 
                    onClick={openConnectModal} 
                    type="button">
                      Connect Wallet
                  </button>
                );
              }

              if (chain.unsupported) {
                return (
                  <button onClick={openChainModal} type="button">
                    Wrong network
                  </button>
                );
              }

              return (
                <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
                  <button
                    onClick={openChainModal}
                    style={{ display: 'flex', alignItems: 'center' }}
                    type="button"
                    className='px-2 md:px-4 py-[2px] md:py-1 font-poppins tracking-tighter text-bg-logo text-sm border-[1px] border-bg-logo hover:bg-bg-logo hover:border-bg-logo hover:text-black duration-200 rounded-l-full rounded-r-full cursor-pointer'
                  >
                    {chain.hasIcon && (
                      <div
                        style={{
                          background: chain.iconBackground,
                          width: 12,
                          height: 12,
                          borderRadius: 999,
                          overflow: 'hidden',
                          marginRight: 4,
                        }}
                      >
                        {chain.iconUrl && (
                          <img
                            alt={chain.name ?? 'Chain icon'}
                            src={chain.iconUrl}
                            style={{ width: 12, height: 12 }}
                          />
                        )}
                      </div>
                    )}
                    {chain.name}
                  </button>

                  <button 
                    onClick={openAccountModal} 
                    type="button"
                    className='px-2 md:px-4 py-[2px] md:py-1 font-poppins tracking-tighter text-bg-logo text-sm border-[1px] border-bg-logo hover:bg-bg-logo hover:border-bg-logo hover:text-black duration-200 rounded-l-full rounded-r-full cursor-pointer'
                  >
                    {account.displayName}
                    {account.displayBalance
                      ? ` (${account.displayBalance})`
                      : ''}
                  </button>
                </div>
              );
            })()}
          </div>
        );
      }}
    </ConnectButton.Custom>
  );
}
 
export default CustomConnectButton;