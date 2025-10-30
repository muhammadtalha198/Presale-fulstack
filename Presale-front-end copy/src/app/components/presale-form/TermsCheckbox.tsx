'use client'

import { useState, useEffect } from "react";

const TermsCheckbox = () => {
  const [isChecked, setIsChecked] = useState<boolean>(false);

  // Cargar estado desde localStorage al montar
  useEffect(() => {
    const savedState = localStorage.getItem('termsAccepted');
    if (savedState) {
      setIsChecked(JSON.parse(savedState));
    }
  }, []);

  // Guardar estado en localStorage cuando cambie
  const handleToggle = () => {
    const newState = !isChecked;
    setIsChecked(newState);
    localStorage.setItem('termsAccepted', JSON.stringify(newState));
  };

  return (
    <label onClick={handleToggle} className="w-full flex items-center justify-start flex-nowrap px-2 py-1 my-2 cursor-pointer">
      <div 
        className={`size-6 ml-2 flex items-center justify-center border-[1px] rounded-md transition-colors duration-200 ${
          isChecked 
            ? 'bg-bg-logo border-bg-logo' 
            : 'border-body-text hover:border-bg-logo'
        }`}
      >
        {isChecked && (
          <svg 
            className="size-4 text-black" 
            fill="currentColor" 
            viewBox="0 0 20 20"
          >
            <path 
              fillRule="evenodd" 
              d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" 
              clipRule="evenodd" 
            />
          </svg>
        )}
      </div>
      
      <div className="flex w-full mx-4 flex-col items-start justify-center">
        <span className="w-full text-[12px] md:text-sm text-bg-logo font-light leading-relaxed">
          I declare that I have read the $ESCROW whitepaper, Terms & Conditions, and other disclosures on this site and I want to participate in the $ESCROW Token Presale.
        </span>
      </div>
    </label>
  );
}

export default TermsCheckbox;