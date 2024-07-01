import * as React from 'react';
import {
  AppBar,
  TitlePortal,
  useTranslate,
} from 'react-admin';
import {
  Switch,
  Box,
  Typography,
} from '@mui/material';
import { IsAdminContext } from '../isAdminContext';

const SwitchButton = () => {
  const { isAdmin, adminMode, setAdminMode } = React.useContext(IsAdminContext);
  const translate = useTranslate();
  const handleChange = (event: React.ChangeEvent<HTMLInputElement>) => {
    setAdminMode(event.target.checked);
  };
  if (!isAdmin) return null
  return (<Box sx={{ display: "inline-flex", mr: 2 }}>
    <Typography sx={{ pt: 1 }}>{translate("other.changeMode")}</Typography>
    <Switch
      checked={adminMode}
      onChange={handleChange}
    />
  </Box>

  )
};

const MyAppBar = () => (
  <AppBar>
    <TitlePortal />
    <SwitchButton />
  </AppBar>
);

export default MyAppBar;
