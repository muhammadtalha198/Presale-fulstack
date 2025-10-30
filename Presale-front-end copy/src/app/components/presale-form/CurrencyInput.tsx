import { useState } from "react";

type Props = {
  currencyBalance: number;
  currencyIconURL: string;
  currencySymbol: string;
  usdValue: number;
  value?: number;
  onChange?: (value: number) => void;
}

const CurrencyInput = ({ currencyBalance, currencyIconURL, currencySymbol, usdValue, value, onChange }: Props) => {

  const [internalValue, setInternalValue] = useState<number>(0);
  
  // Use controlled value if provided, otherwise use internal state
  const currencyQuantity = value !== undefined ? value : internalValue;
  
  const handleChange = (newValue: number) => {
    if (onChange) {
      onChange(newValue);
    } else {
      setInternalValue(newValue);
    }
  };

  const getUSDValue = (quantity: number) => (Boolean(quantity) ? quantity : 0) * usdValue;
  
  return (
    <label className="w-full flex items-center justify-center flex-nowrap px-2 py-1 my-2 border-[1px] border-body-text rounded-l-md rounded-r-lg">
      <img className="size-6 ml-2" src={currencyIconURL} alt={currencySymbol + ' logo'} />
      <div className="flex w-full mx-4 flex-col items-center justify-start">
        <input 
          className="w-full p-0 m-0 text-sm md:text-base text-bg-logo font-medium placeholder:font-light"
          type="number" 
          onChange={(e) => handleChange(parseFloat(e.target.value) || 0)} 
          step={'any'}
          value={currencyQuantity || ''}
          max={currencyBalance}
          min={0}
          placeholder={'0.0'}
        />
        <span className="w-full text-[12px] md:text-sm text-bg-logo font-light text-left">$ {getUSDValue(currencyQuantity).toFixed(3)} </span>
      </div>
      <button type="button" className="font-medium bg-bg-logo text-black px-3 py-1 md:px-4 md:py-2 rounded-l-md rounded-r-md text-nowrap cursor-pointer box-border" onClick={() => handleChange(currencyBalance)}>
        Max Amount
      </button>
    </label>
  );
}
 
export default CurrencyInput;