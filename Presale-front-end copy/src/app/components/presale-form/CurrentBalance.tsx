import { Currency } from "./PresaleForm";

type Props = {
  currentBalance: number;
  currency: Pick<Currency, 'symbol'|'iconURL'>;
}

const CurrentBalance = ({ currentBalance, currency: { iconURL, symbol } }: Props) => {
  return (
    <div className="w-fit mb-3 flex items-center justify-start bg-body-text px-2 py-1 rounded-l-full rounded-r-full">
      <span className="text-bg-logo font-light text-sm">Current balance: &nbsp; </span>
      <span className="text-bg-logo font-medium text-sm"> { currentBalance } { symbol } </span>
      <img className="size-4 ml-2" src={iconURL} alt={symbol + ' logo'} />
    </div>
  );
}
 
export default CurrentBalance;