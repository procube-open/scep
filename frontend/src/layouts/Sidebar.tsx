import React from 'react';
import { useLocation } from 'react-router-dom';
import { Sidebar, Menu, useTranslate } from 'react-admin';
import { FaUser, FaFile } from "react-icons/fa";

const CustomSidebar = () => {
  const location = useLocation();
  const translate = useTranslate();
  return (
    <Sidebar>
      <Menu>
        <Menu.Item
          to="/client"
          primaryText={translate("client.title")}
          leftIcon={<FaUser />}
          selected={location.pathname === '/clients'}
        />
        <Menu.Item
          to="/files/"
          primaryText={translate("files.title")}
          leftIcon={<FaFile />}
          selected={location.pathname === '/files'}
        />
      </Menu>
    </Sidebar>
  );
};

export default CustomSidebar;