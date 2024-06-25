import { createContext, useState, Dispatch, SetStateAction, ReactNode } from 'react';

type IsAdminType = {
  isAdmin: boolean,
  setIsAdmin: Dispatch<SetStateAction<boolean>>
  adminMode: boolean,
  setAdminMode: Dispatch<SetStateAction<boolean>>
}
export const IsAdminContext = createContext({} as IsAdminType);

export const IsAdminProvider = (props: { children: ReactNode }) => {
  const { children } = props;
  const [isAdmin, setIsAdmin] = useState(false);
  const [adminMode, setAdminMode] = useState(false);
  return (
    <IsAdminContext.Provider value={{ isAdmin: isAdmin, setIsAdmin: setIsAdmin, adminMode: adminMode, setAdminMode: setAdminMode }}>
      {children}
    </IsAdminContext.Provider>
  );
};